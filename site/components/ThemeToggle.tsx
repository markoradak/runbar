"use client";

import { useEffect, useState } from "react";
import styles from "./ThemeToggle.module.css";

type Theme = "light" | "dark";

/**
 * The app is appearance-adaptive, so the site is too. Default comes from the
 * media query in globals.css; this only writes `data-theme` once the visitor
 * makes an explicit choice. The pre-paint script in layout.tsx replays that
 * choice on the next visit.
 */
export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme | null>(null);

  useEffect(() => {
    const stored = localStorage.getItem("theme") as Theme | null;
    if (stored === "light" || stored === "dark") {
      setTheme(stored);
      return;
    }
    setTheme(
      window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light",
    );
  }, []);

  const toggle = () => {
    const next: Theme = theme === "dark" ? "light" : "dark";
    setTheme(next);
    document.documentElement.dataset.theme = next;
    localStorage.setItem("theme", next);
  };

  return (
    <button
      type="button"
      className={styles.toggle}
      onClick={toggle}
      // Until the effect runs the rendered theme is unknown, so the control is
      // unlabelled rather than mislabelled.
      aria-label={
        theme ? `Switch to ${theme === "dark" ? "light" : "dark"} theme` : "Toggle theme"
      }
      title="Toggle theme"
    >
      <svg width="15" height="15" viewBox="0 0 24 24" aria-hidden="true">
        {theme === "dark" ? (
          <path
            d="M21 13.2A9 9 0 1 1 10.8 3a7 7 0 0 0 10.2 10.2Z"
            fill="currentColor"
          />
        ) : (
          <>
            <circle cx="12" cy="12" r="4.2" fill="currentColor" />
            <path
              d="M12 2v2.4M12 19.6V22M4.2 4.2l1.7 1.7M18.1 18.1l1.7 1.7M2 12h2.4M19.6 12H22M4.2 19.8l1.7-1.7M18.1 5.9l1.7-1.7"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
            />
          </>
        )}
      </svg>
    </button>
  );
}
