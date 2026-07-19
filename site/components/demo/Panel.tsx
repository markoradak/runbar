"use client";

import { useEffect, useRef, useState } from "react";
import { DotMatrix } from "@/components/DotMatrix";
import { ProviderIcon } from "./ProviderIcon";
import {
  durationText,
  progressState,
  relativeText,
  type RecentRun,
  type RunningRun,
} from "./model";
import styles from "./panel.module.css";

export function Panel({
  running,
  recent,
  clock,
  version,
}: {
  running: RunningRun[];
  recent: RecentRun[];
  /** Seconds on the panel clock since mount. */
  clock: number;
  version: string | null;
}) {
  /*
   * Mirrors statusAccent in RunbarMenuView: running is blue, a recent failure
   * is red, otherwise green. Only the newest completed run decides the failure
   * state — the pinned failed row further down the list is history, not the
   * current status, and letting it count would pin the tile red forever.
   */
  const iconState: IconState =
    running.length > 0
      ? "running"
      : recent[0]?.conclusion === "failure"
        ? "failure"
        : "idle";

  return (
    <div className={styles.panel}>
      <header className={styles.header}>
        <IconTile state={iconState} />
        <div className={styles.headerText}>
          <span className={`mono ${styles.wordmark}`}>runbar</span>
          <span className={styles.statusLine}>
            <span className={`mono ${styles.caret} ${ACCENT[iconState]}`}>❯</span>
            <span className={`mono ${styles.statusText}`}>
              {iconState === "running"
                ? `${running.length} running`
                : iconState === "failure"
                  ? "recent failure"
                  : "all pipelines passing"}
            </span>
          </span>
        </div>
        <span className="pill">
          <span className="pill__dot" style={{ background: "var(--green)" }} />
          @markoradak
        </span>
      </header>

      <div className={styles.hairline} />

      <div className={styles.content}>
        <section className={styles.section}>
          <SectionHeader
            title="running"
            count={running.length}
            accent={running.length ? "blue" : "muted"}
          />
          {running.length === 0 ? (
            <EmptyRunning />
          ) : (
            running.map((run) => (
              <RunningCard key={run.id} run={run} clock={clock} />
            ))
          )}
        </section>

        <section className={styles.section}>
          <SectionHeader title="recent" count={recent.length} accent="muted" />
          <div className={styles.recentList}>
            {recent.map((run) => (
              <RecentRow key={run.id} run={run} clock={clock} />
            ))}
          </div>
        </section>
      </div>

      <div className={styles.hairline} />

      <footer className={styles.footer}>
        <div className={styles.footerMeta}>
          <span className={`mono ${styles.syncText}`}>
            synced {relativeText(clock % 300)}
          </span>
          {/* `getLatestRelease` returns a null version when the GitHub API is
              unreachable. Omit the label rather than fall back to a literal,
              which would quietly show the wrong version every release after
              the one it was written against. */}
          {version ? (
            <span className={`mono ${styles.versionText}`}>v{version}</span>
          ) : null}
        </div>
        <div className={styles.footerButtons}>
          <FooterButton label="Refresh now" d="M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6" />
          <FooterButton
            label="Settings"
            d="M12 15.5A3.5 3.5 0 1 0 12 8.5a3.5 3.5 0 0 0 0 7Zm7.4-2.6.1-.9-.1-.9 1.9-1.5-1.9-3.2-2.3.8a7 7 0 0 0-1.6-.9L15.1 2h-3.7l-.4 2.4a7 7 0 0 0-1.6.9l-2.3-.8-1.9 3.2L7.1 9.2a7.4 7.4 0 0 0 0 1.8l-1.9 1.5 1.9 3.2 2.3-.8c.5.4 1 .7 1.6.9l.4 2.4h3.7l.4-2.4c.6-.2 1.1-.5 1.6-.9l2.3.8 1.9-3.2-1.9-1.5Z"
          />
          <FooterButton
            label="Quit Runbar"
            d="M12 3v9m6.4-6.4a9 9 0 1 1-12.8 0"
          />
        </div>
      </footer>
    </div>
  );
}

/* ----------------------------------------------------------------- header -- */

type IconState = "running" | "failure" | "idle";

/** Accent class per status, applied to both the tile and the ❯ caret. */
const ACCENT: Record<IconState, string> = {
  running: styles.accentBlue,
  failure: styles.accentRed,
  idle: styles.accentGreen,
};

const TILE_STATE: Record<IconState, string> = {
  running: styles.appTileRunning,
  failure: styles.appTileFailure,
  idle: styles.appTileIdle,
};

function IconTile({ state }: { state: IconState }) {
  return (
    <span className={`${styles.appTile} ${TILE_STATE[state]}`}>
      {/* The mark inherits the tile's accent, and only runs the trail while
          something is in flight — so it reads as a status indicator. */}
      <DotMatrix size={20} animate={state === "running"} />
    </span>
  );
}

/* --------------------------------------------------------- section header -- */

function SectionHeader({
  title,
  count,
  accent,
}: {
  title: string;
  count: number;
  accent: "blue" | "muted";
}) {
  return (
    <div className={styles.sectionHeader}>
      <span className={`mono ${styles.sectionTitle}`}>{title}</span>
      <span className={styles.sectionRule} />
      <span
        className={`mono ${styles.sectionCount} ${
          accent === "blue" ? styles.countBlue : styles.countMuted
        }`}
      >
        {count}
      </span>
    </div>
  );
}

function EmptyRunning() {
  return (
    <div className={styles.emptyRunning}>
      <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
        <circle cx="12" cy="12" r="10" fill="var(--green)" opacity="0.85" />
        <path
          d="m7.5 12.4 3 3 6-6.4"
          stroke="var(--wash-raised)"
          strokeWidth="2.4"
          fill="none"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
      <span className={`mono ${styles.emptyText}`}>no active pipelines</span>
    </div>
  );
}

/* ---------------------------------------------------------- running card -- */

function RunningCard({ run, clock }: { run: RunningRun; clock: number }) {
  const elapsed = Math.max(0, clock - run.startedAtClock);
  const state = progressState(elapsed, run.medianSeconds);

  return (
    <article className={styles.runningCard}>
      <div className={styles.cardTop}>
        <ProviderIcon provider={run.provider} size={28} />
        <div className={styles.cardIdentity}>
          <div className={styles.cardTitleRow}>
            <span className={styles.runTitle}>{run.workflow}</span>
            {run.provider === "github" && (
              <span className={`mono ${styles.workflowBadge}`}>workflow</span>
            )}
          </div>
          <span className={`mono ${styles.repoName}`}>{run.repo}</span>
        </div>
        <span className={`mono ${styles.elapsedBadge}`}>
          <span className={styles.elapsedDot} />
          {durationText(elapsed)}
        </span>
      </div>

      <div className={styles.chipRow}>
        <MetaChip icon="branch" text={run.branch} />
        <MetaChip icon="bolt" text={run.event} />
      </div>

      {state === "noHistory" && (
        <span className={`mono ${styles.noHistory}`}>no duration history</span>
      )}

      {state === "estimated" && run.medianSeconds !== null && (
        <div className={styles.progressGroup}>
          <ProgressBar
            fraction={elapsed / run.medianSeconds}
            tone="blue"
          />
          <div className={`mono ${styles.progressMeta}`}>
            <span>median {durationText(run.medianSeconds)}</span>
            <span>~{durationText(run.medianSeconds - elapsed)} left</span>
          </div>
        </div>
      )}

      {state === "runningLong" && run.medianSeconds !== null && (
        <div className={styles.progressGroup}>
          <ProgressBar fraction={1} tone="amber" />
          <span className={`mono ${styles.runningLongText}`}>
            running long · median {durationText(run.medianSeconds)}
          </span>
        </div>
      )}
    </article>
  );
}

function ProgressBar({
  fraction,
  tone,
}: {
  fraction: number;
  tone: "blue" | "amber";
}) {
  const pct = Math.min(1, Math.max(0, fraction)) * 100;
  return (
    <div className={styles.track}>
      <div
        className={`${styles.fill} ${
          tone === "amber" ? styles.fillAmber : styles.fillBlue
        }`}
        style={{ width: `max(4px, ${pct}%)` }}
      />
    </div>
  );
}

function MetaChip({ icon, text }: { icon: "branch" | "bolt"; text: string }) {
  return (
    <span className={`mono ${styles.metaChip}`}>
      <svg width="9" height="9" viewBox="0 0 24 24" aria-hidden="true">
        {icon === "branch" ? (
          <path
            d="M6 3v12m0 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm12-9a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 0c0 4-4 5-6 5"
            stroke="currentColor"
            strokeWidth="2.2"
            fill="none"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        ) : (
          <path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z" fill="currentColor" />
        )}
      </svg>
      {text}
    </span>
  );
}

/* ------------------------------------------------------------ recent row -- */

function RecentRow({ run, clock }: { run: RecentRun; clock: number }) {
  const [hovered, setHovered] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const failed = run.conclusion === "failure";
  const showAction = hovered && run.previewUrl;

  return (
    <div
      className={`${styles.recentRow} ${failed ? styles.recentRowFailed : ""} ${
        run.isHead ? styles.recentRowHead : ""
      }`}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      <div className={styles.cardTop}>
        <ProviderIcon
          provider={run.provider}
          size={26}
          badge={run.conclusion}
        />
        <div className={styles.cardIdentity}>
          <div className={styles.cardTitleRow}>
            <span className={styles.runTitle}>{run.workflow}</span>
            {run.isHead && (
              <span className={`mono ${styles.headBadge}`}>HEAD</span>
            )}
            <span className={styles.spacer} />
            <span className={styles.trailing}>
              <span
                className={`mono ${styles.timestamp}`}
                style={{ opacity: showAction ? 0 : 1 }}
              >
                {relativeText(clock - run.completedAtClock)}
              </span>
              {run.previewUrl && (
                <button
                  type="button"
                  className={styles.rowAction}
                  style={{ opacity: showAction ? 1 : 0 }}
                  tabIndex={showAction ? 0 : -1}
                  aria-label="Open deployment"
                >
                  <svg width="9" height="9" viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M7 17 17 7M9 7h8v8"
                      stroke="currentColor"
                      strokeWidth="2.6"
                      fill="none"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </button>
              )}
            </span>
          </div>
          <div className={`mono ${styles.recentMeta}`}>
            <span className={styles.recentRepo}>{run.repo}</span>
            <span>·</span>
            <span className={failed ? styles.textRed : styles.textGreen}>
              {run.conclusion}
            </span>
            <span>·</span>
            <span>{durationText(run.durationSeconds)}</span>
            {failed && run.log && (
              <>
                <span className={styles.spacer} />
                <button
                  type="button"
                  className={styles.chevron}
                  onClick={() => setExpanded((v) => !v)}
                  aria-expanded={expanded}
                  aria-label={expanded ? "Hide failure log" : "Show failure log"}
                >
                  <svg
                    width="10"
                    height="10"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                    style={{
                      transform: expanded ? "rotate(180deg)" : "none",
                      transition: "transform 0.15s ease",
                    }}
                  >
                    <path
                      d="m5 9 7 7 7-7"
                      stroke="currentColor"
                      strokeWidth="2.6"
                      fill="none"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </button>
              </>
            )}
          </div>
        </div>
      </div>

      {failed && expanded && run.log && <TerminalBlock lines={run.log} />}
    </div>
  );
}

/**
 * Mirrors terminalBlock(): always dark regardless of app theme, with the
 * floating copy button pinned bottom-trailing and a check that flashes for
 * 1.2s, same as CopyLogButton.
 */
function TerminalBlock({ lines }: { lines: string[] }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current !== null) window.clearTimeout(timer.current);
    },
    [],
  );

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(lines.join("\n"));
    } catch {
      return;
    }
    setCopied(true);
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setCopied(false), 1200);
  };

  return (
    <div className={styles.terminalWrap}>
      <pre className={`mono ${styles.terminalBlock}`}>
        {lines.map((line, i) => (
          <span
            key={i}
            className={
              line.startsWith("Error:")
                ? styles.logError
                : line.startsWith("Warning:")
                  ? styles.logWarning
                  : styles.logLine
            }
          >
            {line}
            {"\n"}
          </span>
        ))}
      </pre>
      <button
        type="button"
        className={`${styles.copyLog} ${copied ? styles.copyLogDone : ""}`}
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy log"}
        title="Copy log"
      >
        {copied ? (
          <svg width="10" height="10" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="m5 12.5 4.5 4.5L19 7"
              stroke="currentColor"
              strokeWidth="2.8"
              fill="none"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        ) : (
          <svg width="10" height="10" viewBox="0 0 24 24" aria-hidden="true">
            <rect
              x="9"
              y="9"
              width="11"
              height="11"
              rx="2"
              stroke="currentColor"
              strokeWidth="2.2"
              fill="none"
            />
            <path
              d="M5 15V6a1 1 0 0 1 1-1h9"
              stroke="currentColor"
              strokeWidth="2.2"
              fill="none"
              strokeLinecap="round"
            />
          </svg>
        )}
      </button>
    </div>
  );
}

/* ----------------------------------------------------------------- footer -- */

function FooterButton({ label, d }: { label: string; d: string }) {
  return (
    <span className={styles.footerButton} role="img" aria-label={label}>
      <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
        <path
          d={d}
          stroke="currentColor"
          strokeWidth="2"
          fill="none"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  );
}
