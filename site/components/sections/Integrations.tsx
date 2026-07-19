"use client";

import { useState } from "react";
import { ProviderIcon } from "@/components/demo/ProviderIcon";
import { REPO_URL } from "@/lib/release";
import type { Provider } from "@/components/demo/model";
import styles from "./sections.module.css";

const SUPPORTED: {
  provider: Provider;
  name: string;
  detail: string;
}[] = [
  {
    provider: "github",
    name: "GitHub Actions",
    detail: "Workflow runs, jobs and current step, live output and failure logs.",
  },
  {
    provider: "vercel",
    name: "Vercel",
    detail: "Deployments, build state, and a link straight to the preview.",
  },
  {
    provider: "cloudflare",
    name: "Cloudflare Pages",
    detail: "Deployments, build stages, and log tails for failed builds.",
  },
];

/**
 * Builds a prefilled GitHub issue rather than posting anywhere. Runbar has no
 * backend, and a form on this page that quietly submitted somewhere would be
 * the one exception to that — so the request opens on GitHub, under the
 * visitor's own account, where they can edit it before filing.
 *
 * No `labels` parameter: GitHub rejects the URL if the label doesn't exist on
 * the repo yet, which would break the link rather than degrade it.
 */
function issueUrl(service: string, notes: string) {
  const title = `Integration request: ${service.trim()}`;
  const body = [
    "### Service",
    service.trim(),
    "",
    "### What I'd want to see in the menu bar",
    notes.trim() || "_(not specified)_",
    "",
    "---",
    "Sent from the Runbar site.",
  ].join("\n");

  return `${REPO_URL}/issues/new?title=${encodeURIComponent(
    title,
  )}&body=${encodeURIComponent(body)}`;
}

export function Integrations() {
  const [service, setService] = useState("");
  const [notes, setNotes] = useState("");
  const ready = service.trim().length > 0;

  return (
    <div className={styles.integrations}>
      <ul className={styles.providerList}>
        {SUPPORTED.map((s) => (
          <li key={s.provider} className={styles.providerCard}>
            <div className={styles.providerHead}>
              <ProviderIcon provider={s.provider} size={34} />
              <span className="pill pill--green">
                <span className="pill__dot" />
                supported
              </span>
            </div>
            <h3 className={styles.providerName}>{s.name}</h3>
            <p className={styles.providerDetail}>{s.detail}</p>
          </li>
        ))}
      </ul>

      <form
        className={styles.request}
        onSubmit={(e) => {
          e.preventDefault();
          if (!ready) return;
          window.open(
            issueUrl(service, notes),
            "_blank",
            "noopener,noreferrer",
          );
        }}
      >
        <div className={styles.requestHead}>
          <span className="eyebrow">Missing one?</span>
          <h3 className={styles.requestTitle}>Request an integration</h3>
          <p className={styles.requestLede}>
            Opens a prefilled issue on GitHub for you to review and file —
            nothing is sent from this page.
          </p>
        </div>

        <label className={styles.field}>
          <span className={`mono ${styles.fieldLabel}`}>service</span>
          <input
            className={styles.input}
            value={service}
            onChange={(e) => setService(e.target.value)}
            placeholder="CircleCI, Netlify, Buildkite…"
            maxLength={80}
          />
        </label>

        <label className={`${styles.field} ${styles.fieldGrow}`}>
          <span className={`mono ${styles.fieldLabel}`}>
            what you&apos;d want to see <span className={styles.optional}>optional</span>
          </span>
          <textarea
            className={styles.textarea}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Pipeline status per branch, deploy previews, …"
            rows={3}
            maxLength={600}
          />
        </label>

        <button type="submit" className={styles.requestButton} disabled={!ready}>
          <svg width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M7 17 17 7M9 7h8v8"
              stroke="currentColor"
              strokeWidth="2.4"
              fill="none"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          {ready ? `Open issue for ${service.trim()}` : "Open issue on GitHub"}
        </button>
      </form>
    </div>
  );
}
