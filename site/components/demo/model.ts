/*
 * Data model and formatters for the interactive panel, mirroring
 * WorkflowRunPresentation and MenuBarRun in the app.
 */

export type Provider = "github" | "vercel" | "cloudflare";

export type RunningRun = {
  id: string;
  provider: Provider;
  workflow: string;
  repo: string;
  branch: string;
  event: string;
  /**
   * Panel-clock reading at which this run started. Seeds use negative values so
   * they are already mid-flight on first paint.
   */
  startedAtClock: number;
  /**
   * Median of the last 10 completed runs of this workflow. `null` means no
   * history, which the app renders as a bare label with no bar rather than
   * inventing an estimate.
   */
  medianSeconds: number | null;
  /** How long this run actually takes, which may overshoot the median. */
  durationSeconds: number;
  conclusion: "success" | "failure";
};

export type RecentRun = {
  id: string;
  provider: Provider;
  workflow: string;
  repo: string;
  conclusion: "success" | "failure";
  durationSeconds: number;
  /** Panel-clock reading at which this run completed. */
  completedAtClock: number;
  isHead?: boolean;
  previewUrl?: boolean;
  /** Failure log tail, revealed by the row's chevron. */
  log?: string[];
  /**
   * Kept at the bottom of the list and never evicted. The failed row carries
   * the expandable log, so letting completed runs push it out would quietly
   * remove the only place that interaction is discoverable.
   */
  pinned?: boolean;
};

/**
 * Real time. An earlier version ran at 8× so runs would finish quickly, but a
 * seconds digit advancing eight times a second reads as a broken stopwatch, not
 * as a menu-bar app — the once-per-second tick is most of what makes the panel
 * feel real. Liveness comes from seeding runs near their finish instead, so
 * completions still happen while someone is watching.
 */
export const DEMO_SPEED = 1;

export type ProgressState = "estimated" | "runningLong" | "noHistory";

/** Mirrors WorkflowRunPresentation.progressState. */
export function progressState(
  elapsed: number,
  median: number | null,
): ProgressState {
  if (median === null) return "noHistory";
  return elapsed >= median ? "runningLong" : "estimated";
}

/** Mirrors WorkflowRunPresentation.durationText — "1m 12s", "45s". */
export function durationText(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem === 0 ? `${m}m` : `${m}m ${rem}s`;
}

/** Mirrors WorkflowRunPresentation.relativeText — "4m ago". */
export function relativeText(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

export const PROVIDER_LABEL: Record<Provider, string> = {
  github: "GitHub Actions",
  vercel: "Vercel",
  cloudflare: "Cloudflare Pages",
};

/*
 * Two concurrent runs keeps the RUNNING and RECENT sections both visible
 * without scrolling. Between them they show a determinate estimate and an
 * overrun; the third state (no history) is covered by the "no duration
 * history" template below, which the cycle rotates in.
 */
type Template = Omit<RunningRun, "id" | "startedAtClock">;

const TEMPLATES: Template[] = [
  {
    provider: "github",
    workflow: "CI",
    repo: "markoradak/runbar",
    branch: "main",
    event: "push",
    medianSeconds: 134,
    durationSeconds: 190,
    conclusion: "success",
  },
  {
    provider: "cloudflare",
    workflow: "Deploy",
    repo: "acme/platform-api",
    branch: "main",
    event: "push",
    medianSeconds: 150,
    durationSeconds: 320,
    conclusion: "success",
  },
  {
    provider: "vercel",
    workflow: "Lighthouse",
    repo: "markoradak/site",
    branch: "perf/lcp",
    event: "pull_request",
    medianSeconds: null,
    durationSeconds: 240,
    // One template fails so the cycle actually exercises the red status state.
    // With every run succeeding, the menu-bar icon could only ever be blue or
    // green and the failure accent would be unreachable.
    conclusion: "failure",
  },
];

/** Attached to runs that complete as failures, so their row can expand. */
export const COMPLETED_FAILURE_LOG = [
  "Run npx lhci autorun",
  "✓ Collected 3 runs against http://localhost:3000",
  "Warning: largest-contentful-paint 3.4s (budget 2.5s)",
  "Error: Assertion failed: categories.performance 0.71 < 0.90",
  "Error: Process completed with exit code 1.",
];

/**
 * One run at a time, rotating through the templates so a visitor who watches
 * for a while sees every progress state. Deliberately not a pair: two running
 * cards squeeze the RECENT list below the fold of the panel's scroll area,
 * which hides the failed row and its expandable log.
 *
 * The second template starts already past its median so the overrun state shows
 * up immediately when its turn comes round.
 */
export function cycleRuns(cycle: number, clock: number): RunningRun[] {
  const template = TEMPLATES[cycle % TEMPLATES.length];
  // Enters with ~26s left to run, so a completion lands within a plausible
  // dwell time even though the clock ticks at 1×.
  const headStart = template.durationSeconds - 26;
  return [{ ...template, id: `c${cycle}`, startedAtClock: clock - headStart }];
}

/**
 * Seed state: one run 84% of the way through its median, finishing ~24s after
 * the page loads.
 */
export const SEED_RUNNING: RunningRun[] = [
  { ...TEMPLATES[0], id: "seed-a", startedAtClock: -124 },
];

export const SEED_RECENT: RecentRun[] = [
  {
    id: "h1",
    provider: "github",
    workflow: "Release",
    repo: "markoradak/shiftover",
    conclusion: "success",
    durationSeconds: 64,
    completedAtClock: -240,
    isHead: true,
  },
  {
    id: "h2",
    provider: "github",
    workflow: "Tests",
    repo: "markoradak/runbar",
    conclusion: "failure",
    durationSeconds: 47,
    completedAtClock: -1_020,
    log: [
      "Run swift test --enable-code-coverage",
      "Building for debugging...",
      "[142/142] Compiling RunbarTests",
      "Test Suite 'PollSchedulerTests' started",
      "Warning: rate limit headers missing on 2 responses",
      'Error: XCTAssertEqual failed: ("304") is not equal to ("200")',
      "  PollSchedulerTests.swift:118",
      "Test Suite 'PollSchedulerTests' failed",
      "Error: Process completed with exit code 1.",
    ],
    pinned: true,
  },
  {
    id: "h3",
    provider: "vercel",
    workflow: "Preview",
    repo: "markoradak/site",
    conclusion: "success",
    durationSeconds: 38,
    completedAtClock: -2_400,
    previewUrl: true,
  },
];

/** The run that arrives when the visitor simulates a push. */
export function pushedRun(id: string, clock: number): RunningRun {
  return { ...TEMPLATES[0], id, startedAtClock: clock };
}
