import styles from "./sections.module.css";

/** Exactly what the GitHub App asks for, and everything it deliberately doesn't. */
const GRANTED = [
  { scope: "Actions", access: "read", note: "run status and history" },
  { scope: "Metadata", access: "read", note: "mandatory for any GitHub App" },
];

const WITHHELD = [
  "Contents",
  "Workflows",
  "Pull requests",
  "Issues",
  "Deployments",
  "Packages",
  "Administration",
  "Secrets",
];

export function ScopeList() {
  return (
    <div className={styles.scopes}>
      <div className={styles.scopeHead}>
        <span className="eyebrow">Requested permissions</span>
        <span className="pill pill--green">
          <span className="pill__dot" />2 of 10
        </span>
      </div>

      <ul className={styles.scopeGranted}>
        {GRANTED.map((g) => (
          <li key={g.scope} className={styles.scopeRow}>
            <svg
              width="13"
              height="13"
              viewBox="0 0 24 24"
              aria-hidden="true"
              className={styles.scopeCheck}
            >
              <circle cx="12" cy="12" r="10" fill="currentColor" />
              <path
                d="m7.5 12.4 3 3 6-6.4"
                stroke="var(--wash)"
                strokeWidth="2.4"
                fill="none"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
            <span className={`mono ${styles.scopeName}`}>{g.scope}</span>
            <span className={`mono ${styles.scopeAccess}`}>{g.access}</span>
            <span className={styles.scopeNote}>{g.note}</span>
          </li>
        ))}
      </ul>

      <div className={styles.scopeDivider}>
        <span className={`mono ${styles.scopeDividerText}`}>not requested</span>
      </div>

      <ul className={styles.scopeWithheld}>
        {WITHHELD.map((s) => (
          <li key={s} className={`mono ${styles.scopeWithheldItem}`}>
            {s}
          </li>
        ))}
      </ul>

      <p className={styles.scopeFoot}>
        It cannot start, cancel, or re-run anything, and it never reads your
        code.
      </p>
    </div>
  );
}

/** The conditional-request exchange that keeps polling free of rate-limit cost. */
export function ConditionalRequest() {
  return (
    <div className={styles.exchange}>
      <div className={styles.exchangeRow}>
        <span className={`mono ${styles.exchangeVerb}`}>GET</span>
        <span className={`mono ${styles.exchangePath}`}>
          /repos/markoradak/runbar/actions/runs
        </span>
      </div>
      <div className={`mono ${styles.exchangeHeader}`}>
        If-None-Match: <span className={styles.exchangeEtag}>&quot;a3f9c21e&quot;</span>
      </div>

      <div className={styles.exchangeArrow} aria-hidden="true" />

      <div className={styles.exchangeRow}>
        <span className={`mono ${styles.exchangeStatus}`}>304</span>
        <span className={`mono ${styles.exchangePath}`}>Not Modified</span>
      </div>
      <div className={`mono ${styles.exchangeHeader}`}>
        x-ratelimit-remaining:{" "}
        <span className={styles.exchangeUnchanged}>4982 — unchanged</span>
      </div>

      <p className={styles.exchangeNote}>
        Stored ETags mean unchanged repos cost nothing against your rate limit.
        Runbar tracks what&apos;s left and widens its own polling before it ever
        becomes your problem.
      </p>
    </div>
  );
}
