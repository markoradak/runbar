"use client";

import { useEffect, useRef, useState } from "react";
import styles from "./sections.module.css";

/*
 * A chart, not a timer.
 *
 * This started as a looping 5-minute sweep. At a readable rate the bars crawl
 * for eleven seconds while nothing happens, and the one moment that matters —
 * Runbar resolving at 0.9s — is over in the first 0.3% of the rail. Animating
 * an interval whose whole point is that one side is instant just makes the
 * instant side invisible.
 *
 * So the values are fixed and the bars draw in once when scrolled into view.
 * The comparison is a fact about two designs, not an event to watch.
 */

const WINDOW_SECONDS = 300;
const RUNBAR_SECONDS = 0.9;

export function LatencyRace() {
  const [drawn, setDrawn] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setDrawn(true);
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return;
        setDrawn(true);
        observer.disconnect();
      },
      { rootMargin: "0px 0px -15% 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <div className={styles.race} ref={ref}>
      <div className={styles.raceHead}>
        <span className={`mono ${styles.raceEvent}`}>
          <span className={styles.racePulse} />
          git push returns
        </span>
        <span className={`mono ${styles.raceClock}`}>time to first spinner</span>
      </div>

      <Track
        label="Runbar · FSEvents"
        value="0.9s"
        tone="blue"
        /* Floored so the bar stays visible: 0.9s of 300 is 0.3% of the rail,
           which would render as nothing at all. */
        width={drawn ? Math.max(2.5, (RUNBAR_SECONDS / WINDOW_SECONDS) * 100) : 0}
        capped
      />

      <Track
        label="Polling · 5-minute default"
        value="up to 5m"
        tone="muted"
        width={drawn ? 100 : 0}
      />

      <div className={styles.raceAxis}>
        {[0, 1, 2, 3, 4, 5].map((m) => (
          <span key={m} className={`mono ${styles.raceTick}`}>
            {m}m
          </span>
        ))}
      </div>
    </div>
  );
}

function Track({
  label,
  value,
  tone,
  width,
  capped,
}: {
  label: string;
  value: string;
  tone: "blue" | "muted";
  width: number;
  /** Draws the leading edge as a marker, so a 2.5% bar still reads as a point. */
  capped?: boolean;
}) {
  return (
    <div className={styles.track}>
      <div className={styles.trackHead}>
        <span className={`mono ${styles.trackLabel}`}>{label}</span>
        <span
          className={`mono ${styles.trackValue} ${
            tone === "blue" ? styles.valueBlue : styles.valueMuted
          }`}
        >
          {value}
        </span>
      </div>

      <div className={styles.trackRail}>
        <div
          className={`${styles.trackBar} ${
            tone === "blue" ? styles.barBlue : styles.barMuted
          }`}
          style={{ width: `${width}%` }}
        >
          {capped && <span className={styles.trackCap} />}
        </div>
      </div>
    </div>
  );
}
