import styles from "./DotMatrix.module.css";

/**
 * The mark from Design/brand/favicon.svg — a 2x3 dot matrix.
 *
 * The dots animate as a loader: a bright highlight travels clockwise around the
 * grid, leaving a decaying trail behind it. An earlier version pulsed every dot
 * from its own brand opacity toward full, which read as noise rather than as
 * motion — with six different starting opacities there was no sequence to
 * follow. The animation therefore uses a uniform base; the brand's per-dot
 * opacities are what it falls back to when motion is off, where the mark is
 * static and should look like the logo.
 */

// Base opacities from favicon.svg, column-major: col0 rows 0-2, then col1.
const BRAND_OPACITY = [0.85, 0.7, 0.66, 1, 0.25, 0.4];

/*
 * Position of each dot in the travel order. Walking the grid clockwise from the
 * top-left visits col0row0 → col1row0 → col1row1 → col1row2 → col0row2 →
 * col0row1, which in column-major indices is 0 → 3 → 4 → 5 → 2 → 1.
 */
const TRAVEL_POSITION = [0, 5, 4, 1, 2, 3];

const CX = [51.8824, 99.1176];
const CY = [27.7647, 75, 122.235];

export function DotMatrix({
  size = 150,
  /**
   * When false the mark rests at its brand opacities instead of running the
   * trail. The panel's tile uses this to animate only while a run is in
   * flight, mirroring RunbarIconTile's `.running` / `.idle` modes.
   */
  animate = true,
}: {
  size?: number;
  animate?: boolean;
}) {
  return (
    <svg
      className={`${styles.matrix} ${animate ? "" : styles.static}`}
      width={size}
      height={size}
      viewBox="0 0 150 150"
      fill="none"
      aria-hidden="true"
    >
      {BRAND_OPACITY.map((base, i) => (
        <circle
          key={i}
          className={styles.dot}
          cx={CX[i < 3 ? 0 : 1]}
          cy={CY[i % 3]}
          r={12.8824}
          fill="currentColor"
          style={
            {
              "--base": base,
              // Negative delay of pos/6 of a cycle starts each dot already
              // that far along, so the highlight is spaced evenly around the
              // loop from the first frame. The duration lives in CSS.
              "--pos": TRAVEL_POSITION[i],
            } as React.CSSProperties
          }
        />
      ))}
    </svg>
  );
}
