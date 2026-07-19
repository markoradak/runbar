"use client";

import { useEffect, useRef, useState } from "react";
import styles from "./sections.module.css";

const STEP_MS = 620;
const HOLD_STEPS = 4;

type Candidate = {
  path: string;
  /** What the walker actually found on disk. */
  found: string;
  tracked: boolean;
  /** Why it was rejected, when it was. */
  reason?: string;
};

const CANDIDATES: Candidate[] = [
  {
    path: "runbar/",
    found: ".github/workflows/ci.yml",
    tracked: true,
  },
  {
    path: "dotfiles/",
    found: "no .github/",
    tracked: false,
    reason: "no workflows",
  },
  {
    path: "blog/",
    found: ".github/dependabot.yml",
    tracked: false,
    reason: "not a workflow",
  },
  {
    path: "platform-api/",
    found: ".github/workflows/deploy.yml",
    tracked: true,
  },
  {
    path: "scratch/",
    found: "no .git",
    tracked: false,
    reason: "not a repo",
  },
];

export function RepoScan() {
  /* Fully scanned by default, so the pre-hydration and reduced-motion renders
     show the verdicts rather than five dimmed, unresolved rows. */
  const [step, setStep] = useState(CANDIDATES.length);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setStep(CANDIDATES.length);
      return;
    }

    let timer: number | null = null;
    let running = false;

    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting && !running) {
        running = true;
        timer = window.setInterval(() => {
          setStep((s) => (s + 1) % (CANDIDATES.length + HOLD_STEPS));
        }, STEP_MS);
      } else if (!entry.isIntersecting && running) {
        running = false;
        if (timer !== null) window.clearInterval(timer);
      }
    });

    observer.observe(node);
    return () => {
      observer.disconnect();
      if (timer !== null) window.clearInterval(timer);
    };
  }, []);

  const tracked = CANDIDATES.filter((c, i) => c.tracked && i < step).length;

  return (
    <div className={styles.scan} ref={ref}>
      <div className={styles.scanHead}>
        <span className={`mono ${styles.scanPath}`}>~/Code</span>
        <span className={`mono ${styles.scanDepth}`}>walking to depth 4</span>
      </div>

      <ul className={styles.scanList}>
        {CANDIDATES.map((c, i) => {
          const resolved = i < step;
          const active = i === step;

          return (
            <li
              key={c.path}
              className={`${styles.scanRow} ${resolved ? styles.scanRowResolved : ""} ${
                active ? styles.scanRowActive : ""
              }`}
            >
              <span className={`mono ${styles.scanName}`}>{c.path}</span>
              <span className={`mono ${styles.scanFound}`}>{c.found}</span>
              <span className={styles.scanVerdict}>
                {resolved ? (
                  c.tracked ? (
                    <span className="pill pill--green">
                      <span className="pill__dot" />
                      tracked
                    </span>
                  ) : (
                    <span className={`mono ${styles.scanSkipped}`}>
                      {c.reason}
                    </span>
                  )
                ) : active ? (
                  <span className={`mono ${styles.scanScanning}`}>
                    <span className={styles.scanSpinner} />
                    reading
                  </span>
                ) : null}
              </span>
            </li>
          );
        })}
      </ul>

      <div className={styles.scanFoot}>
        <span className={`mono ${styles.scanCount}`}>
          {tracked} repo{tracked === 1 ? "" : "s"} added · 0 asked about
        </span>
      </div>
    </div>
  );
}
