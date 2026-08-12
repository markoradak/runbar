# Adding an integration

What it takes to add an execution provider to Runbar, what disqualifies one, and how the
request-to-release pipeline moves an issue through it.

This file is the contract. The automation in `.github/workflows/integration-*.yml` reads it as its
source of truth, so it is a document for humans first and a prompt second — keep it that way. If a
rule lives only in workflow YAML it will drift; put it here.

## The pipeline

| Stage | Trigger | Actor | Ends with |
| --- | --- | --- | --- |
| Request | Settings → Accounts in the app, the form on getrunbar.app, or the issue template | The requester | An issue labeled `integration-request` |
| Triage | That label | `integration-triage.yml` | A feasibility brief, or a decline + close |
| Build | You applying `ready-to-build` | `integration-build.yml` | A PR labeled `integration` |
| Review | The build workflow dispatching it | `integration-review.yml` | An approving review, or requested changes |
| Merge + release | You | You | `scripts/release.sh minor` |

The gate at "you applying `ready-to-build`" is deliberate. The request form is public and
unauthenticated, so anything upstream of that label is open to strangers; nothing downstream of it
spends real time or ships code without a human deciding it should.

The three request routes converge on one issue on purpose. The app links to the issue *template*
rather than carrying `?labels=` the way the site's form does — see `RunbarLinks`; a URL compiled
into a shipped binary is permanent, and GitHub rejects the whole URL if a label named in it is ever
deleted. Renaming or removing `.github/ISSUE_TEMPLATE/integration-request.yml` therefore degrades
every installed copy to GitHub's issue chooser rather than breaking it, but it does drop the label,
and triage would then be relying on its title-prefix fallback.

The gate at merge is also deliberate, and is the one worth re-reading before anyone is tempted to
close it. A merge here is not a merge — pushing a `v*` tag builds, notarizes, and publishes a
signed Sparkle appcast, and **every installed copy auto-updates from it within the hour**. The app
is unsandboxed and holds users' provider tokens in their Keychain. Meanwhile the integration was
written from published API docs by someone who never held a token for that provider, and the test
suite proves only that the fixtures we invented decode into the shapes we expected. Neither Claude
in this pipeline can close that gap; both read the same docs. A human connecting a real token and
watching one deployment go from building to ready is the only thing that does.

## What disqualifies a provider

Triage checks these before anything else. Any one of them is a decline, and the decline should
explain which and why rather than trailing off into "not a good fit".

1. **No public HTTP API returning JSON.** Scraping a dashboard is not an integration.
2. **Auth that needs a backend.** A static token in a header is the whole budget. An OAuth
   authorization-code flow needs a redirect URI and a client secret, which needs a server, which is
   invariant #1 in `docs/ARCHITECTURE.md`. Device-flow is the one exception the codebase already
   makes, for GitHub, and it took a GitHub App to do it.
3. **No account-wide list endpoint.** Runbar shows builds across everything you own without being
   told what to watch. A provider that can only answer "status of pipeline X" — where the user must
   name X — cannot deliver that. Per-project endpoints are acceptable *only* if some endpoint first
   enumerates the projects, which is how Cloudflare Pages works.
4. **No read-only credential.** Invariant #6: Runbar never triggers, cancels, or re-runs anything.
   If the narrowest token the provider issues can also start a deploy, say so loudly in the brief —
   it is not an automatic decline, but it is the user's Keychain and their blast radius.
5. **Rate limits that a 60-second account-wide poll would exhaust.** See below; this is the one
   that gets waved through and shouldn't be.

## The poll budget is the shared resource

Every external provider is polled on **one account-wide timer**, not per repository
(`ExternalProviderMonitor`). One tick calls `fetch(token:)` on every connected client, so request
cost is per-provider-per-tick and adding a provider raises the floor for everyone:

| Tier | Interval | When |
| --- | --- | --- |
| Local-push burst | 1s…9s, then 10s | `hotWindowDuration` (90s) after FSEvents sees a push |
| Menu open | 5s | While the user is looking at the popover |
| Active | 30s | Any execution is running |
| Idle | 60s | Everything else |

Below 100 remaining, every interval widens 4× and the menu bar shows the degraded state.

Two consequences a code review will not surface on its own:

- **A brief must state the per-tick request count**, and it must be O(1) or O(scopes) — never
  O(projects). `CloudflarePagesClient` costs one verify + one accounts call + one project list per
  account. `VercelClient` would cost a page walk per tick, so it caches the account census
  (`/v2/user`, `/v2/teams`, the `/v9/projects` walk) for 15 minutes and a warm tick costs one
  request per scope. If a provider cannot be made to fit that, it does not fit the timer.
- **The idle interval is what decides whether a build is ever seen at all.** The push burst only
  covers deployments a local push created; a dashboard redeploy, a CLI deploy, a merged PR, or a
  repo with no local clone produces no push signal and is polled at exactly 60s. Provider builds
  routinely finish in 25–45s. A provider whose builds are shorter than that will show up as "it
  sometimes just doesn't notice", and no amount of correct decoding fixes it.

## The terminal-state trap

Map running states as a **whitelist**. Only states that genuinely mean "still going" map to a
running status; everything unrecognized maps to finished.

This is not a style preference. Vercel has terminal states that never build and so never
progress — `BLOCKED` when the account hits a spend limit, plus `SKIPPED` and `DELETED` — and a
fallback that read unknown states as queued left them spinning in the Running section forever. That
shipped, and `ec60293` fixed it. The asymmetry is the point: misreading a *new in-flight* state as
finished self-corrects on the next poll, and misreading a *terminal* one as running never does.

## The checklist

A PR that skips any of these is incomplete. Model the client on
`Sources/Runbar/Networking/CloudflarePagesClient.swift` — it is the smaller of the two.

### Swift

- [ ] `Sources/Runbar/Domain/WorkflowRun.swift` — add the `ExecutionProvider` case and fill in
      `displayName`, `shortName`, `systemImage`. **The `rawValue` is persisted in SQLite's
      `provider_runs.provider` column and can never change after it ships.** `externalProviders`
      derives from `allCases`, so nothing else needs finding by hand.
- [ ] `Sources/Runbar/Networking/<Provider>Client.swift` — conform to `ExternalProviderClient`
      (`fetch(token:)` and `logLines(externalID:projectKey:token:)`). Route every request through
      `ProviderHTTP.get`, which owns auth headers, status→`ProviderClientError` mapping, and
      rate-limit parsing. Take `transport:`, `baseURL:`, and `now:` as injected initializer
      parameters exactly as the existing clients do — that is what makes it testable.
- [ ] `Sources/Runbar/Keychain/ProviderCredentialStore.swift` — one entry in `.production`, service
      `app.runbar.Runbar.<slug>`. Invariant #2: the token goes nowhere else, ever, including logs.
- [ ] `Sources/Runbar/App/RunbarApp.swift` — add the client to the `clients:` array.
- [ ] `Sources/Runbar/Features/MenuBar/ProviderBrandMark.swift` — case, brand color, simple-icons
      24×24 path data, `paths` entry, and the `brandMark` switch. Monochrome marks use
      `Color.primary.opacity(0.88)` so they follow the theme; only keep a brand color when the logo
      is meaningless without it, as Cloudflare's orange is.
- [ ] `Sources/Runbar/Features/Settings/SettingsView.swift` — a `providerCard(...)` with the token
      URL and the exact permission scope to select, plus the Keychain disclosure line that names
      each provider.
- [ ] `Sources/Runbar/Features/Settings/RunLogStreamer.swift` — add the case to **both**
      `switch item.run.provider` sites so failed-build log tailing routes through the monitor.

`SQLiteProviderStore` and `ExternalProviderMonitor` are generic over provider and should not need
editing. If a change there looks necessary, that is a design smell worth raising in the PR rather
than pushing through — it is shared by every other integration.

### Tests

- [ ] `Tests/RunbarTests/ExternalProviderClientTests.swift` — a `ProviderMockTransport` case
      covering the real response shape, every state in the whitelist, at least one state *outside*
      it proving it lands as finished, and rate-limit header parsing.
- [ ] No existing test modified or deleted. If an existing assertion now fails, the change is
      wrong until proven otherwise.
- [ ] `scripts/test.sh` green.

### Site and docs

The site advertises the supported set; a PR that ships the Swift alone makes it lie.

- [ ] `site/components/demo/model.ts` — the `Provider` union and `PROVIDER_LABEL`
- [ ] `site/components/demo/ProviderIcon.tsx` — the `Mark` branch, mirroring the app's tile
- [ ] `site/components/sections/Integrations.tsx` — the `SUPPORTED` entry
- [ ] `README.md` and the external-providers section of `docs/ARCHITECTURE.md`

### Never

- [ ] Touch `.github/workflows/{ci,release}.yml`, `scripts/release.sh`, or `project.yml`.
- [ ] Add a dependency. Runbar has exactly one (Sparkle) and ships as one bundle.
- [ ] Issue a non-GET request. Invariant #6, and the only exception in the codebase is GitHub's
      device-flow sign-in.

## Versioning

A new provider is a feature: `scripts/release.sh minor`. Patch releases are for fixes to providers
that already ship.
