# Architecture

How Runbar works, and — just as important — why several obvious alternatives were evaluated and
rejected. If you're about to propose webhooks, GraphQL, or a git hook: they're at the bottom,
with the reasoning.

## Invariants

These are load-bearing. A change that conflicts with one of them is wrong by definition.

1. **No backend.** One app bundle. No server, no relay, no hosted component.
2. **Credentials live in the macOS Keychain.** Never in `UserDefaults`, a plist, a file on disk,
   or a log line.
3. **Every GitHub poll is a conditional request** — stored ETag + `If-None-Match`. A 304 does not
   count against the primary rate limit when the request carries a valid `Authorization` header.
   This single mechanism is what makes client-side multi-repo polling viable at all.
4. **Elapsed time is computed locally**, from `run_started_at` and a local clock. The API is
   polled to learn about *state transitions*, not to tick a timer. Timers keep counting offline.
5. **Never exhaust the rate limit.** Track `x-ratelimit-remaining`/`reset` on every response;
   degrade visibly when it runs low. Never silently keep hammering.
6. **Read-only.** The GitHub App requests `Actions: read` plus the mandatory `Metadata: read` —
   not even Contents. The app never triggers, cancels, or re-runs anything; the only non-GET
   request in the codebase is device-flow sign-in.

## The central constraint

**There is no cross-repo "list all my workflow runs" endpoint.** Runs are queryable only per
repository (`GET /repos/{owner}/{repo}/actions/runs`). The "runs across all repos" view must be
assembled client-side by merging per-repo results — the entire architecture exists to do that
without burning the 5,000 req/hour rate limit.

## Components

### Repo discovery (`Discovery/`)

The set of repos to watch is the union of two sources, refreshed on launch and every ~30 minutes:

- **Local scan** of the user's code root, max depth 4, for directories containing `.git` whose
  `origin` resolves to GitHub (SSH, SCP, and HTTPS forms). Only repos with at least one
  `.github/workflows/*.y{a,}ml` qualify — `.github/` alone also holds issue templates and
  `dependabot.yml`, which don't imply Actions. Workflow files are parsed locally (names,
  triggers), which is why the app never needs the Contents scope.
- **`GET /user/repos?sort=pushed`**, top 30, for repos with CI you care about but haven't cloned.

Users can exclude repos; they are never required to add one. Locally checked-out workflow files
may be stale relative to the default branch — accepted, because the API is the source of truth
for runs; the local scan only decides *who to ask*.

### GitHub client (`Networking/GitHubClient.swift`)

Owns the ETag layer explicitly: SQLite cache keyed by canonical URL, each record transactionally
coupling the ETag with the exact response body; 304s decode only the stored body. `URLSession`
runs with `urlCache = nil` and a reload-ignoring policy — deliberately, because `URLCache`
handles conditional requests transparently and returns a **200 with the cached body**, which
makes a broken ETag layer look correct and a correct one look broken.

Per-repo 403/404 (an App installation is scoped per resource owner; repos in orgs without the
installation return these) marks the repo inaccessible once, surfaces it in Settings with a
retry action, and stops polling it. Backoff on 403/429 respects `retry-after`.

Denied repos recover in two ways without the manual retry. Discovery restores any denied repo
that reappears in the installation-repositories feed — presence there is authoritative, absence
proves nothing (the remote list is capped). Everything else gets probed automatically on a
capped backoff (1h → 6h → daily per consecutive denial, `RepositoryAccessRetryPolicy`), driven
from the launch, periodic-refresh, and wake paths; probes bypass the local access gate so GitHub
delivers the verdict, and a denied probe just re-stamps the backoff without re-notifying.

### Poll scheduler (`Polling/PollScheduler.swift`)

Each repo sits in exactly one tier:

| Tier | Condition | Interval |
|---|---|---|
| Hot | a run is `queued` or `in_progress` | 8s |
| Warm | pushed or completed a run within the hour | 60s |
| Cold | everything else | 10 min |

Every interval is jittered ±15% so polls don't fire in lockstep. Hot repos mostly return 200
(the run's `updated_at` keeps changing) and cost quota — expected. Warm/cold mostly return 304
and cost nothing. Reconciliation sweeps poll every known repo once on launch and on
wake-from-sleep, because a sleeping laptop misses transitions. Below 500 remaining, all
intervals widen 4× and the menu bar shows an amber degraded state; recovery restores them.

### Git watcher (`Git/GitWatcher.swift`)

Near-zero-cost local push detection. FSEvents watches, per repo, **both**
`.git/refs/remotes/origin/` *and* `.git/packed-refs` — git writes either, and watching only
loose refs silently misses repos with packed refs. A remote-ref change promotes the repo to Hot
and opens a **post-push window** (60s): an immediate poll, then re-polls tightening on 2s/4s/8s
into the 8s Hot cadence. The window exists because GitHub queues the run a few seconds *after*
`git push` returns — a single immediate poll almost always finds nothing, and (before this) the
empty result demoted the repo to Warm/Cold, so the run only surfaced 30s–10m later. The window
keeps polling until the run appears (then normal Hot polling takes over) or it expires; every
request is conditional, so the extra polls are almost all free 304s until the run exists. It also
tracks `.git/HEAD` and the current SHA per repo, which powers the "this run is the commit you're
sitting on" accent (matched by `head_sha`). Worktrees are supported.

### Persistence (`Persistence/`)

Raw SQLite via the system library — one `runbar.sqlite3` in Application Support, WAL, busy
timeout. Shared plumbing lives in `SQLiteSupport.swift` (connection lifetime, open/schema
guard, statement helpers); each store contributes only its schema and queries. Runs older than
~30 days are pruned; enough completed-run history is kept per workflow to compute duration
medians. Known issue: the six stores open separate connections and create schema independently —
see issue #1 before adding a seventh store.

### ETA (`WorkflowRunPresentation`)

For an in-progress run: median duration of the last ten completed runs of the same
`workflow_id` (`updated_at − run_started_at`), rendered as elapsed/median. Median, not
last-build — one fast failure would poison a last-build estimate. Past 100% the bar does not
clamp and pretend: it switches to indeterminate and says "running long". No history → plain
elapsed timer, no bar.

### External providers (`Providers/`, `Networking/{Vercel,CloudflarePages}Client.swift`)

Vercel and Cloudflare Pages deployments normalize into the same execution model and merge into
the same UI. Shared HTTP layer (`ProviderHTTP`) handles auth headers, status validation, and
rate-limit parsing. Neither API supports ETags, so instead of tiers the monitor uses a post-push
burst that ramps 1s…9s and then holds at 10s for the rest of the hot window, a menu-open interval
(5s), an active interval (30s), and an idle interval (60s); a 429's `Retry-After` is honored per
provider, and remaining quota below 100 widens polling 4× — providers publish very different quota
totals, so the threshold is absolute rather than GitHub's 500-of-5,000. Opening the menu resyncs
immediately and then polls at the menu interval, and tightens whatever tier applies but never
loosens it: a build running while the user watches is the case that most needs the fast cadence.

The idle interval is the one that decides whether a deployment is ever seen *while it runs*.
Unlike GitHub, which is polled per repository (so the aggregate cadence across many repos is
dense), providers are polled account-wide on a single timer. The post-push burst only covers
deployments a local push created — a dashboard redeploy, a CLI deploy, a PR merge, or a repo
with no local clone produces no push signal at all, and is polled at exactly the idle rate.
Provider builds routinely finish in 25-45s, so the idle interval must stay tight enough to land
inside one. What makes those cadences affordable is `VercelClient`'s account census cache
(`censusTTL`): `/v2/user`, `/v2/teams`, and the `/v9/projects` page walk describe the account
shape, not its activity, so they are walked once every 15 minutes rather than every poll. A warm
poll costs one request per scope, so poll cost scales with scopes, not with cadence.

Two rules keep a finished deployment from spinning in the Running section forever. First, state
mapping is a whitelist: only the states that genuinely mean "still going" (`QUEUED`,
`INITIALIZING`, `BUILDING`) map to a running status, and anything unrecognized maps to finished.
Vercel has terminal states that never build and so never progress — `BLOCKED` when the account
hits a plan or spend limit, plus `SKIPPED` and `DELETED` — and a fallback that read unknown
states as queued left them running indefinitely. Misreading a *new* in-flight state as finished
self-corrects on the next poll; misreading a terminal one as running never does.

Second, saving a fetch reconciles: unfinished rows for that provider are cleared before the
response is re-inserted, so a run only stays "running" while the provider keeps reporting it.
That covers the rows the first rule cannot — a deployment dropped at ingest (an auto-skipped one)
or aged out of the fetch window would otherwise persist until the 30-day prune.

`SQLitePollStore.saveWorkflowRuns` reconciles the same way for GitHub, since an upsert can only
update rows the response still mentions: a run deleted from the Actions UI, or pushed out of the
20 most recent by newer ones, would otherwise spin forever. It deletes only the unfinished rows
*missing* from the response rather than clearing and re-inserting — `menu_timer_debug` cascades
on `runs.id`, so clearing live rows each poll would discard the active run's timer history.
Both reconcilers depend on their caller passing a complete response; on the GitHub side a 304
replays the cached body rather than an empty list, so a revalidated poll re-affirms in-flight
runs instead of erasing them.

### Menu bar UI (`Features/MenuBar/`)

A window-style popover (`.menuBarExtraStyle(.window)`), not a native `NSMenu` — live timers,
custom rows, and scrolling don't work inside a real menu. The icon has five states (running /
idle / recent failure / rate-limit degraded / auth needed) and is **always visible**: a
monitoring tool that hides when healthy is indistinguishable from one that crashed. The degraded
and auth-failed states are not optional — a tool that silently stops working is worse than one
that says it's broken.

## Evaluated and rejected

Recorded so they don't get re-proposed every quarter. Each of these was considered seriously.

**Webhooks / a GitHub App with event subscriptions.** A webhook needs a publicly reachable HTTPS
endpoint; a laptop isn't one, so it would require a relay — which violates the no-backend
invariant. Worse: GitHub does **not** automatically redeliver failed webhook deliveries; a
sleeping laptop *loses events*, so a REST reconciliation sweep is required regardless. Webhooks
could reduce polling; they can never eliminate it. FSEvents already delivers the latency win for
your own pushes, free. Revisit only at hundreds-of-org-repos scale, where the reconciliation
code stays as-is and a relay becomes an addition rather than a rewrite.

**GraphQL.** Would batch many repos into one request — but the GraphQL API does not support
conditional requests: no ETags, no free 304s. That trades away the mechanism that keeps the app
under the rate limit, and the Actions data exposed via GraphQL is thinner than REST.

**A `pre-push` git hook.** Cleaner push signal than FSEvents, but requires writing a hook into
every repo the user owns. Too invasive; FSEvents needs no cooperation from the repo.

**The user events feed as a discovery source.** Redundant: FSEvents catches local pushes with
lower latency, and `/user/repos?sort=pushed` already catches recency.

**App Sandbox.** Off, deliberately: scanning an arbitrary user-chosen folder and holding
long-lived FSEvents watches across it are unreliable under sandbox security-scoped bookmarks,
and this is direct distribution, not the App Store. Hardened runtime stays on (notarization
requires it).
