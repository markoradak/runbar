import { PROVIDER_LABEL, type Provider } from "./model";
import styles from "./panel.module.css";

/**
 * Mirrors ProviderIconTile: a rounded tile at radius `size * 0.28`, filled at
 * 5.5% primary with a 9% border, holding the brand mark at `size * 0.56`.
 * GitHub and Vercel are monochrome (88% primary) so they adapt to the theme;
 * Cloudflare keeps its brand orange (#F6821F), exactly as the app does.
 */
export function ProviderIcon({
  provider,
  size = 28,
  badge,
}: {
  provider: Provider;
  size?: number;
  /** Conclusion dot pinned to the bottom-trailing corner, as on recent rows. */
  badge?: "success" | "failure";
}) {
  return (
    <span
      className={styles.tile}
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.28,
      }}
      role="img"
      aria-label={PROVIDER_LABEL[provider]}
    >
      <Mark provider={provider} size={size * 0.56} />
      {badge && (
        <span
          className={`${styles.tileBadge} ${
            badge === "success" ? styles.badgeGreen : styles.badgeRed
          }`}
        />
      )}
    </span>
  );
}

function Mark({ provider, size }: { provider: Provider; size: number }) {
  const common = { width: size, height: size, viewBox: "0 0 24 24" };

  if (provider === "github") {
    return (
      <svg {...common} className={styles.markMono} aria-hidden="true">
        <path
          fill="currentColor"
          d="M12 .5A11.5 11.5 0 0 0 .5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.56-.29-5.25-1.28-5.25-5.7 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.79 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.12 3.05.74.81 1.18 1.84 1.18 3.1 0 4.43-2.69 5.4-5.26 5.69.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12 11.5 11.5 0 0 0 12 .5Z"
        />
      </svg>
    );
  }

  if (provider === "vercel") {
    return (
      <svg {...common} className={styles.markMono} aria-hidden="true">
        <path fill="currentColor" d="M12 2 23 21H1L12 2Z" />
      </svg>
    );
  }

  return (
    <svg {...common} aria-hidden="true">
      <path
        fill="#F6821F"
        d="M16.85 15.3c.15-.53.09-1.02-.17-1.38-.24-.33-.64-.52-1.12-.55l-9.16-.11a.18.18 0 0 1-.14-.08.18.18 0 0 1-.02-.17c.03-.08.1-.14.19-.15l9.24-.12c1.1-.05 2.29-.94 2.7-2.02l.53-1.37a.32.32 0 0 0 .01-.18 6.03 6.03 0 0 0-11.6-.62 2.71 2.71 0 0 0-4.24 2.68A3.85 3.85 0 0 0 0 14.98c0 .19.01.37.04.55.01.09.09.15.17.15h16.918a.21.21 0 0 0 .2-.15l-.478-.23Z"
      />
      <path
        fill="#F6821F"
        opacity="0.7"
        d="M19.7 9.6h-.26a.15.15 0 0 0-.14.1l-.36 1.25c-.16.53-.1 1.02.17 1.38.24.33.64.52 1.12.55l1.95.12c.06 0 .11.03.14.08a.18.18 0 0 1 .02.17c-.03.08-.1.14-.19.15l-2.03.12c-1.1.05-2.29.94-2.7 2.02l-.15.38a.1.1 0 0 0 .09.14h6.98a.18.18 0 0 0 .17-.13c.12-.43.19-.89.19-1.36a4.7 4.7 0 0 0-4.7-4.7"
      />
    </svg>
  );
}
