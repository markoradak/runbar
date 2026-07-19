"use client";

import { useEffect, useRef, useState } from "react";
import { ProviderIcon } from "@/components/demo/ProviderIcon";
import styles from "./sections.module.css";

/** Mirrors the app's failure-log tail, including its Error:/Warning: colouring. */
const LOG = [
  "Run swift test --enable-code-coverage",
  "Building for debugging...",
  "[142/142] Compiling RunbarTests PollSchedulerTests.swift",
  "Test Suite 'All tests' started at 2026-07-18 21:03:58",
  "Test Suite 'PollSchedulerTests' started",
  "Warning: rate limit headers missing on 2 responses",
  "Test Case '-[PollSchedulerTests testConditionalRequestSkipsUnchanged]' started",
  'Error: XCTAssertEqual failed: ("304") is not equal to ("200")',
  "  PollSchedulerTests.swift:118",
  "Test Case '-[PollSchedulerTests testConditionalRequestSkipsUnchanged]' failed (0.412 seconds)",
  "Test Suite 'PollSchedulerTests' failed at 2026-07-18 21:04:11",
  "  Executed 47 tests, with 1 failure (0 unexpected) in 3.109 seconds",
  "Error: Process completed with exit code 1.",
];

/** The app flashes its check for 1.2s before reverting. */
const COPIED_MS = 1200;

export function FailureLog() {
  const [expanded, setExpanded] = useState(true);
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current !== null) window.clearTimeout(timer.current);
    },
    [],
  );

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(LOG.join("\n"));
      setCopied(true);
      setFailed(false);
    } catch {
      // Clipboard access can be denied by permissions policy or an insecure
      // context. Say so rather than flashing a success state that didn't happen.
      setFailed(true);
      return;
    }
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setCopied(false), COPIED_MS);
  };

  return (
    <div className={styles.failure}>
      <div className={styles.failureRow}>
        <ProviderIcon provider="github" size={26} badge="failure" />
        <div className={styles.failureIdentity}>
          <div className={styles.failureTitleRow}>
            <span className={styles.failureTitle}>Tests</span>
            <span className={`mono ${styles.failureBadge}`}>workflow</span>
          </div>
          <div className={`mono ${styles.failureMeta}`}>
            <span>markoradak/runbar</span>
            <span>·</span>
            <span className={styles.failureWord}>failure</span>
            <span>·</span>
            <span>47s</span>
          </div>
        </div>
        <button
          type="button"
          className={styles.failureChevron}
          onClick={() => setExpanded((v) => !v)}
          aria-expanded={expanded}
          aria-label={expanded ? "Hide failure log" : "Show failure log"}
        >
          <svg
            width="11"
            height="11"
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
      </div>

      {expanded && (
        <div className={styles.failureTerminal}>
          <pre className={`mono ${styles.failureLog}`}>
            {LOG.map((line, i) => (
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
            className={`${styles.copyButton} ${copied ? styles.copyButtonDone : ""}`}
            onClick={copy}
            aria-label={copied ? "Copied" : "Copy log"}
          >
            {copied ? (
              <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="m5 12.5 4.5 4.5L19 7"
                  stroke="currentColor"
                  strokeWidth="2.6"
                  fill="none"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            ) : (
              <svg width="12" height="12" viewBox="0 0 24 24" aria-hidden="true">
                <rect
                  x="9"
                  y="9"
                  width="11"
                  height="11"
                  rx="2"
                  stroke="currentColor"
                  strokeWidth="2"
                  fill="none"
                />
                <path
                  d="M5 15V6a1 1 0 0 1 1-1h9"
                  stroke="currentColor"
                  strokeWidth="2"
                  fill="none"
                  strokeLinecap="round"
                />
              </svg>
            )}
            <span className={`mono ${styles.copyLabel}`}>
              {copied ? "copied" : failed ? "copy blocked" : "copy log"}
            </span>
          </button>
        </div>
      )}
    </div>
  );
}
