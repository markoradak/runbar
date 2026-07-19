import { durationText } from "@/components/demo/model";
import styles from "./sections.module.css";

/*
 * Deliberately static. This section is a side-by-side comparison of three
 * states, not a second live demo — animating the clocks here made three sets of
 * digits spin at once and turned a readable comparison into noise. The hero
 * carries the liveness; this carries the explanation.
 */

type State = {
  workflow: string;
  repo: string;
  elapsed: number;
  median: number | null;
  overrun?: boolean;
  note: string;
};

const STATES: State[] = [
  {
    workflow: "CI",
    repo: "markoradak/runbar",
    elapsed: 112,
    median: 134,
    note: "Determinate bar, measured against the median of the last 10 completed runs — not the last one, so a single fast failure can't poison the estimate.",
  },
  {
    workflow: "Deploy",
    repo: "acme/platform-api",
    elapsed: 96,
    median: 48,
    overrun: true,
    note: "Past its median. The bar switches to indeterminate and says so, rather than sitting at 99% pretending it knows.",
  },
  {
    workflow: "Lighthouse",
    repo: "markoradak/site",
    elapsed: 26,
    median: null,
    note: "First run of this workflow. No history means a plain elapsed timer and no bar, rather than an invented number.",
  },
];

export function ProgressStates() {
  return (
    <div className={styles.states}>
      {STATES.map((s) => (
        <article key={s.workflow} className={styles.stateCard}>
          <div className={styles.stateHead}>
            <span className={styles.stateWorkflow}>{s.workflow}</span>
            <span
              className={`mono ${styles.stateElapsed} ${
                s.overrun ? styles.stateElapsedAmber : ""
              }`}
            >
              {durationText(s.elapsed)}
            </span>
          </div>
          <span className={`mono ${styles.stateRepo}`}>{s.repo}</span>

          <div className={styles.stateProgress}>
            {s.median === null ? (
              <span className={`mono ${styles.stateNoHistory}`}>
                no duration history
              </span>
            ) : s.overrun ? (
              <>
                <div className={styles.stateTrack}>
                  <div className={styles.stateIndeterminate} />
                </div>
                <span className={`mono ${styles.stateOverrun}`}>
                  running long · median {durationText(s.median)}
                </span>
              </>
            ) : (
              <>
                <div className={styles.stateTrack}>
                  <div
                    className={`${styles.stateFill} ${styles.stateFillBlue}`}
                    style={{ width: `${(s.elapsed / s.median) * 100}%` }}
                  />
                </div>
                <div className={`mono ${styles.stateMeta}`}>
                  <span>median {durationText(s.median)}</span>
                  <span>~{durationText(s.median - s.elapsed)} left</span>
                </div>
              </>
            )}
          </div>

          <p className={styles.stateNote}>{s.note}</p>
        </article>
      ))}
    </div>
  );
}
