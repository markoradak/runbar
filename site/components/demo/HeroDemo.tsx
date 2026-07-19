"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Panel } from "./Panel";
import {
  COMPLETED_FAILURE_LOG,
  DEMO_SPEED,
  SEED_RECENT,
  SEED_RUNNING,
  cycleRuns,
  pushedRun,
  type RecentRun,
  type RunningRun,
} from "./model";
import styles from "./demo.module.css";

const TICK_MS = 100;

/** The app's headline claim: spinner within ~1s of `git push` returning. */
const DETECTION_DELAY_MS = 900;

/** Real-time pause between the last run finishing and a fresh one starting. */
const RESEED_DELAY_MS = 3600;

export function HeroDemo({ version }: { version: string | null }) {
  const [clock, setClock] = useState(0);
  const [running, setRunning] = useState<RunningRun[]>(SEED_RUNNING);
  const [recent, setRecent] = useState<RecentRun[]>(SEED_RECENT);
  const [phase, setPhase] = useState<"idle" | "pushing" | "detected">("idle");
  const [visible, setVisible] = useState(true);
  const [animated, setAnimated] = useState(true);

  const wrapRef = useRef<HTMLDivElement>(null);
  const clockRef = useRef(0);
  const pushCount = useRef(0);
  const cycleRef = useRef(0);
  const reseedTimer = useRef<number | null>(null);

  /*
   * The clock is derived from timestamps rather than accumulated per tick.
   * Browsers throttle setInterval in background tabs to about 1Hz, which would
   * silently slow an accumulating clock to a fraction of its intended rate;
   * deriving from Date.now() means throttling costs smoothness, not accuracy.
   * `accRef` banks elapsed demo-time so the clock freezes while off-screen
   * instead of jumping forward when the visitor scrolls back.
   */
  const accRef = useRef(0);
  const resumedAt = useRef<number | null>(null);

  clockRef.current = clock;

  useEffect(() => {
    const node = wrapRef.current;
    if (!node) return;
    const observer = new IntersectionObserver(
      ([entry]) => setVisible(entry.isIntersecting),
      { rootMargin: "120px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!visible) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setAnimated(false);
      return;
    }

    resumedAt.current = Date.now();
    const bank = () => {
      if (resumedAt.current === null) return;
      accRef.current += ((Date.now() - resumedAt.current) / 1000) * DEMO_SPEED;
      resumedAt.current = null;
    };

    const id = window.setInterval(() => {
      if (resumedAt.current === null) return;
      const live =
        accRef.current +
        ((Date.now() - resumedAt.current) / 1000) * DEMO_SPEED;
      setClock(live);
    }, TICK_MS);

    return () => {
      bank();
      window.clearInterval(id);
    };
  }, [visible]);

  // Retire finished runs into the recent list.
  useEffect(() => {
    const done = running.filter(
      (r) => clock - r.startedAtClock >= r.durationSeconds,
    );
    if (done.length === 0) return;

    setRunning((prev) =>
      prev.filter((r) => clock - r.startedAtClock < r.durationSeconds),
    );
    setRecent((prev) => {
      const arrivals: RecentRun[] = done.map((r) => ({
        id: `done-${r.id}`,
        provider: r.provider,
        workflow: r.workflow,
        repo: r.repo,
        conclusion: r.conclusion,
        durationSeconds: r.durationSeconds,
        completedAtClock: r.startedAtClock + r.durationSeconds,
        // Vercel rows carry a deployment link, which is what reveals the
        // hover action on the row's trailing edge.
        previewUrl: r.provider === "vercel" && r.conclusion !== "failure",
        // Failures need a log, or their row renders a chevron that expands to
        // nothing.
        log: r.conclusion === "failure" ? COMPLETED_FAILURE_LOG : undefined,
      }));

      // HEAD marks the run matching the local checkout, so at most one row can
      // ever wear it — give it to the newest GitHub arrival and clear the rest.
      const newestGitHub = arrivals.find((r) => r.provider === "github");
      if (newestGitHub) newestGitHub.isHead = true;

      const pinned = prev.filter((r) => r.pinned);
      const rest = prev
        .filter((r) => !r.pinned)
        .map((r) => (newestGitHub ? { ...r, isHead: false } : r));

      return [...arrivals, ...rest].slice(0, 3).concat(pinned);
    });
  }, [clock, running]);

  // Keep the panel alive: once everything finishes, start a fresh pair.
  useEffect(() => {
    if (running.length > 0 || !visible) return;
    if (reseedTimer.current !== null) return;

    reseedTimer.current = window.setTimeout(() => {
      cycleRef.current += 1;
      setRunning(cycleRuns(cycleRef.current, clockRef.current));
      reseedTimer.current = null;
    }, RESEED_DELAY_MS);

    return () => {
      if (reseedTimer.current !== null) {
        window.clearTimeout(reseedTimer.current);
        reseedTimer.current = null;
      }
    };
  }, [running.length, visible]);

  const simulatePush = useCallback(() => {
    if (phase !== "idle") return;
    setPhase("pushing");

    window.setTimeout(() => {
      pushCount.current += 1;
      setRunning((prev) => [
        pushedRun(`push-${pushCount.current}`, clockRef.current),
        ...prev,
      ]);
      setPhase("detected");
      window.setTimeout(() => setPhase("idle"), 2600);
    }, DETECTION_DELAY_MS);
  }, [phase]);

  return (
    <div className={styles.wrap} ref={wrapRef}>
      <div className={styles.pushBar}>
        <div className={styles.pushLine}>
          <span className={`mono ${styles.prompt}`}>$</span>
          <span className={`mono ${styles.pushCmd}`}>git push</span>
          {phase !== "idle" && (
            <span className={`mono ${styles.pushStatus}`}>
              {phase === "pushing" ? (
                <>
                  <span className={styles.spinner} />
                  writing objects…
                </>
              ) : (
                <>
                  <span className={styles.tick}>▸</span>
                  detected in 0.9s
                </>
              )}
            </span>
          )}
        </div>
        <button
          type="button"
          className={styles.pushButton}
          onClick={simulatePush}
          disabled={phase !== "idle"}
        >
          {phase === "idle" ? "Run it" : "Watching…"}
        </button>
      </div>

      <Panel
        running={running}
        recent={recent}
        clock={clock}
        version={version}
      />

      <p className={`mono ${styles.caption}`}>
        {animated
          ? "Live demo · real seconds, real states — press Run it"
          : "Demo paused · your system is set to reduced motion"}
      </p>
    </div>
  );
}
