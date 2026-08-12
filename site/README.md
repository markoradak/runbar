# Runbar landing page

A Next.js static site for [runbar](https://github.com/markoradak/runbar). Lives in
the app repo so the download button, version string, and release assets can never
drift apart — but shares none of the Swift toolchain.

```bash
pnpm install
pnpm dev           # http://localhost:3000
pnpm build
pnpm typecheck
```

Uses pnpm — `pnpm-lock.yaml` is the committed lockfile and Vercel detects the
package manager from it. Don't add a `package-lock.json` alongside it; two
lockfiles make Vercel's package-manager detection ambiguous.

## Design

The palette is ported from the app's own `MenuTheme`
(`Sources/Runbar/Features/MenuBar/RunbarMenuView.swift`), which the source calls a
"devops console" look: a warm paper wash (`#FAF8F4` light, `#191814` dark) rather
than neutral gray, surfaces built from low-opacity overlays on `Color.primary`
rather than hardcoded grays, mono type for every label and pill, and Apple's
semantic system colors for status.

Tokens live in `app/globals.css` as custom properties and keep the overlay
approach rather than flattening to hex, so nested surfaces stack the same way
they do in SwiftUI.

On macOS, `--font-sans` and `--font-mono` resolve to SF Pro and SF Mono — the
same typefaces the app draws with.

## The hero demo

`components/demo/` is a working recreation of the status-item panel, not a
screenshot. Metrics in `panel.module.css` are transcribed from
`RunbarMenuView.swift` rather than approximated — 420px card, radius 20, the
9.5/10/10.5/11.5 mono sizes, the 4px gradient progress bar, the dashed empty
state.

- **`model.ts`** ports `WorkflowRunPresentation`: `durationText`,
  `relativeText`, and the three-way `progressState` (determinate estimate /
  overrun / no history).
- **`HeroDemo.tsx`** owns the clock and run lifecycle. Runs progress, overrun
  their median, complete into the RECENT list, and a fresh one cycles in.
  "Run it" simulates a push and lands a new run 0.9s later — the app's headline
  claim, demonstrated rather than asserted.

Two things worth knowing before editing it:

The clock is **derived from timestamps**, not accumulated per tick. Browsers
throttle `setInterval` to ~1Hz in background tabs, which silently slows an
accumulating clock to a fraction of its rate; deriving from `Date.now()` means
throttling costs smoothness, not accuracy. Elapsed demo-time is banked when the
panel scrolls out of view so it freezes rather than jumping on return.

The panel content has a **fixed height**. Letting it size to its content made
the whole hero reflow every time a run finished and a card left the list.

## The body sections

`components/sections/` follows the same show-don't-tell approach:

- **`LatencyRace`** — a static bar chart: 0.9s against a 5-minute poll window,
  drawn in once on reveal. It was a looping sweep first, but animating an
  interval whose whole point is that one side is instant only makes the instant
  side invisible — the bar resolved in the first 0.3% of the rail and the other
  eleven seconds were dead air. The Runbar bar has a 2.5% floor so it renders at
  all, with a leading-edge cap so it still reads as a point in time.
- **`ProgressStates`** — the three progress states side by side. Deliberately
  **static**: animating three clocks at once turned a readable comparison into
  three sets of spinning digits.
- **`FailureLog`** — the expandable failure tail with a real copy-to-clipboard
  button, flashing a check for 1.2s to match `CopyLogButton`.
- **`RepoScan`** — walks five candidate directories and shows each verdict.
  `blog/` holds only `dependabot.yml` and is rejected, which is the concrete
  version of "the presence of `.github/` alone isn't enough".
- **`Integrations`** — the three supported providers, plus a request form.
- **`ScopeList`** — 2 of 10 permissions granted, the other 8 struck through.
- **`Reveal`** — scroll-triggered fade, revealing once and then disconnecting.
- **`DotMatrix`** — the brand mark as a loader. A highlight travels clockwise
  around the 2x3 grid leaving a decaying trail, driven by a negative
  `animation-delay` per dot. It has to animate from a *uniform* base: pulsing
  each dot from its own brand opacity gave six different starting points and no
  sequence to follow, which read as noise. The brand's per-dot opacities are the
  reduced-motion fallback, where the mark is static and should look like a logo.

### Pacing

The panel clock runs at **1×**. An earlier version ran at 8× so runs would
finish quickly, but a seconds digit advancing eight times a second reads as a
broken stopwatch rather than a menu-bar app — the once-per-second tick is most
of what sells it. Liveness comes from seeding runs near their finish instead, so
completions still land within a plausible dwell time. Only the hero animates a
clock; every other section shows fixed numbers.

### The integration request

`Integrations` builds a prefilled `github.com/.../issues/new` URL and opens it —
it does not post anywhere. Runbar has no backend, and a form on this page that
quietly submitted somewhere would be the one exception to that, so the request
lands on GitHub under the visitor's own account where they can edit it first.

No `labels` parameter: GitHub rejects the URL outright if the label doesn't
exist on the repo, which breaks the link rather than degrading it. If you add an
`integration-request` label or an issue template later, wire it in there.

### One trap worth knowing

CSS Modules are scoped per file, and a class that isn't in the imported
stylesheet resolves to `undefined` — no error, no type failure, just an element
with no class. That shipped dark log text onto the dark terminal once already.
`logLine` / `logError` / `logWarning` are intentionally defined in **both**
`panel.module.css` and `sections.module.css` for this reason.

Every animated component here shares two rules. Each **initialises to its
finished state**, not a zero clock — that value is what the server renders, what
a visitor sees before hydration, and what reduced-motion keeps, and an empty
rail reads as broken rather than as "not started". And each **pauses via
IntersectionObserver** when scrolled out of view.

`Reveal` starts at `opacity: 0`, so `layout.tsx` carries a `<noscript>` rule
targeting `[data-reveal]`. Without it, a visitor with JS disabled would get a
page whose sections never appear.

## The download button

The release workflow publishes a *versioned* asset name (`Runbar-0.1.6.zip`, see
`.github/workflows/release.yml`), so there is no stable
`releases/latest/download/<name>` URL to hardcode. `lib/release.ts` reads the
exact filename back from the GitHub API with a one-hour ISR revalidate, and
degrades to a plain link to the releases page if the call fails. Nothing here
needs updating at release time.

## Deploying

Vercel project settings:

| Setting | Value |
| --- | --- |
| Root Directory | `site` |
| Framework preset | Next.js |
| Install command | auto (pnpm, from `pnpm-lock.yaml`) |
| `NEXT_PUBLIC_SITE_URL` | the production URL, once a domain is attached |

`NEXT_PUBLIC_SITE_URL` only affects the absolute URLs in the OG/Twitter tags; it
defaults to `https://getrunbar.app`. Not `runbar.app` — that domain is registered
but parked without a certificate, and crawlers fetching `og:image` over the wire
would fail every unfurl while the page itself kept looking fine.

Two guards keep the Swift and web halves of the repo from triggering each
other's builds:

- `vercel.json` sets `ignoreCommand` so commits that don't touch `site/` skip the
  Vercel build.
- `.github/workflows/ci.yml` has `paths-ignore: ['site/**', ...]` so a CSS tweak
  doesn't boot a macOS runner and run the Swift test suite.

The `ignoreCommand` has a consequence worth knowing before it confuses you. It
exits **0** when `site/` is untouched, and Vercel reads exit 0 as *ignore this
build*, which the dashboard reports as **Canceled** — a healthy skip that looks
like a failure. So the deployed site is not HEAD; it is the last commit that
touched `site/`, and a run of Swift-only commits leaves it several behind.
Redeploying HEAD does not help, because the redeploy re-runs the same check and
skips again.

Nothing here reads from the deployment, so being behind is normally harmless:
the release data comes from the GitHub API at runtime (`lib/release.ts`). It
stops being harmless when a **Vercel environment variable changes**, since those
bind at build time. Adding or rotating `REVALIDATE_SECRET` has no effect until a
build actually runs, and the endpoint fails closed, so the symptom is a flat 401
from a correctly configured project. To force one, redeploy the most recent
deployment whose commit touched `site/` — check with
`git diff --quiet <sha>^ <sha> -- site/` — or push a commit that does.

The app updates itself through Sparkle against GitHub Releases
(`SUFeedURL` in `Sources/Runbar/Info.plist`), not through this site — a broken
deploy here cannot affect installed apps.

## OG image

Not built yet. `app/opengraph-image.tsx` would be the place; the metadata in
`app/layout.tsx` already declares the tags.
