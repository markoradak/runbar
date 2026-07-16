# Runbar

A native macOS menu-bar monitor for GitHub Actions, Vercel, and Cloudflare Pages — across every
repo you already have checked out, with **zero manual repo configuration**.

Sign in, point it at your code folder, done. It finds the repos itself.

## Why another CI menu bar app

There are several, and they work. Two things here are genuinely different:

**The spinner appears ~1 second after `git push` returns.** Runbar watches your checkouts with
FSEvents — `.git/refs/remotes/origin/` *and* `.git/packed-refs`, because git writes to either —
and promotes a repo the instant its remote-tracking ref moves. It doesn't wait for a poll tick.
The closest comparable app polls on a five-minute default.

**The progress bar tells the truth.** The ETA is the median of the last 10 completed runs of that
same workflow, not the last one — so a single fast failure doesn't poison the estimate. When a run
overruns its median, the bar does *not* sit at 99% pretending: it switches to indeterminate and
says "running long". No history for a workflow means a plain elapsed timer and no bar, rather than
an invented number.

## How it finds your repos

Two sources, unioned and deduped, refreshed on launch and every ~30 minutes:

- **Your code folder**, walked to depth 4, for anything with a `.git` and at least one
  `.github/workflows/*.y{a,}ml`. The presence of `.github/` alone isn't enough — that directory
  also holds issue templates and `dependabot.yml`, which don't imply Actions.
- **`GET /user/repos?sort=pushed`**, top 30, as a safety net for repos you care about but haven't
  cloned.

You can *exclude* repos. You are never asked to *add* one.

## Privacy and access

- **Read-only. Always.** Runbar requests `Actions: read` plus the mandatory `Metadata: read`.
  Nothing else — not even Contents. It cannot start, cancel, or re-run anything, and it never
  reads your code.
- **No backend.** One app bundle. No server, no relay, no telemetry, no analytics, no account.
- **Credentials live in the macOS Keychain.** Never in `UserDefaults`, a plist, a file, or a log
  line.
- **Every poll is a conditional request.** Stored ETags plus `If-None-Match`, so unchanged repos
  return 304 and cost nothing against your rate limit. Runbar tracks `x-ratelimit-remaining` and
  widens its own polling before it ever becomes your problem.

## Install

Requires macOS 14+. Download the latest `.zip` from
[Releases](https://github.com/markoradak/runbar/releases); it updates itself via Sparkle.

## Build from source

```bash
./bootstrap.sh    # checks toolchain, installs xcodegen if missing, generates the project
open Runbar.xcodeproj
```

## Architecture

The design — and the reasoning behind the non-obvious choices — is written down in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): the ETag-conditional polling model, the tiered
scheduler, the FSEvents watcher, the honest ETA, and the alternatives that were evaluated and
rejected (webhooks, GraphQL, git hooks) with the reasoning kept so they don't get re-litigated.

## Contributing

Issues and PRs welcome. Two things worth reading first:

- The invariants and the "evaluated and rejected" section in
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). If a change conflicts with an invariant, the
  change is wrong — that's what makes it an invariant.
- The open issues are real and honestly described, including the known architectural ones.

Run the tests with `scripts/test.sh`.

## License

MIT — see [`LICENSE`](LICENSE).

Built by [Marko Radak](https://github.com/markoradak).
