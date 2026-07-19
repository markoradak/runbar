import { DotMatrix } from "@/components/DotMatrix";
import { HeroDemo } from "@/components/demo/HeroDemo";
import { ThemeToggle } from "@/components/ThemeToggle";
import { FailureLog } from "@/components/sections/FailureLog";
import { Integrations } from "@/components/sections/Integrations";
import { LatencyRace } from "@/components/sections/LatencyRace";
import { ProgressStates } from "@/components/sections/ProgressStates";
import { RepoScan } from "@/components/sections/RepoScan";
import {
  ConditionalRequest,
  ScopeList,
} from "@/components/sections/ScopeList";
import { Reveal } from "@/components/sections/Reveal";
import {
  formatSize,
  getLatestRelease,
  RELEASES_URL,
  REPO_URL,
} from "@/lib/release";
import styles from "./page.module.css";

export default async function Home() {
  const release = await getLatestRelease();
  const size = formatSize(release.size);

  return (
    <>
      <nav className={styles.nav}>
        <div className={`wrap ${styles.navInner}`}>
          <a href="#top" className={styles.navBrand}>
            <DotMatrix size={18} />
            <span className={`mono ${styles.navName}`}>runbar</span>
          </a>
          <div className={styles.navLinks}>
            <a className={styles.navLink} href="#speed">
              Speed
            </a>
            <a className={styles.navLink} href="#logs">
              Logs
            </a>
            <a className={styles.navLink} href="#integrations">
              Integrations
            </a>
            <a className={styles.navLink} href="#privacy">
              Privacy
            </a>
            <a className={styles.navLink} href={REPO_URL}>
              GitHub
            </a>
            <ThemeToggle />
            <a className={styles.navCta} href={release.downloadUrl}>
              Download
            </a>
          </div>
        </div>
      </nav>

      <main id="top">
        {/* ------------------------------------------------------------ hero */}
        <section className={`wrap ${styles.hero}`}>
          <div className={styles.heroCopy}>
            <span className="pill pill--green">
              <span className="pill__dot" />
              {release.version ? `v${release.version}` : "latest"} · macOS 14+
            </span>

            <h1 className={styles.title}>
              Your CI, one second
              <br />
              after <span className={styles.titleMono}>git push</span>.
            </h1>

            <p className={styles.lede}>
              A native macOS menu-bar monitor for GitHub Actions, Vercel, and
              Cloudflare Pages — across every repo you already have checked out.
              Sign in, point it at your code folder, done. It finds the repos
              itself.
            </p>

            <div className={styles.actions}>
              <a className={styles.download} href={release.downloadUrl}>
                <svg
                  width="15"
                  height="15"
                  viewBox="0 0 16 16"
                  fill="none"
                  aria-hidden="true"
                >
                  <path
                    d="M8 1.5v9m0 0L4.5 7M8 10.5 11.5 7M2 12.5v1a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-1"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
                Download for macOS
              </a>
              <a className={styles.secondary} href={REPO_URL}>
                View source
              </a>
            </div>

            <p className={`mono ${styles.fineprint}`}>
              {[
                release.version ? `v${release.version}` : null,
                size,
                "Apple silicon & Intel",
                "updates via Sparkle",
              ]
                .filter(Boolean)
                .join("  ·  ")}
            </p>
          </div>

          <div className={styles.heroPanel}>
            <HeroDemo version={release.version} />
          </div>
        </section>

        {/* ----------------------------------------------------------- speed */}
        <section className={`wrap section ${styles.split}`} id="speed">
          <Reveal className={styles.splitCopy}>
            <span className="eyebrow">Detection latency</span>
            <h2 className="section__title">
              It doesn&apos;t wait for a poll tick.
            </h2>
            <p className="section__lede">
              Runbar watches your checkouts with FSEvents — both{" "}
              <code className={styles.code}>.git/refs/remotes/origin/</code> and{" "}
              <code className={styles.code}>.git/packed-refs</code>, because git
              writes to either — and promotes a repo the instant its
              remote-tracking ref moves.
            </p>
            <p className={styles.splitNote}>
              The closest comparable app polls on a five-minute default. That
              difference is the whole reason this exists.
            </p>
          </Reveal>

          <Reveal className={styles.splitVisual} delay={90}>
            <LatencyRace />
          </Reveal>
        </section>

        {/* -------------------------------------------------------- progress */}
        <section className={`wrap section`} id="progress">
          <Reveal>
            <div className="section__head">
              <span className="eyebrow">Honest estimates</span>
              <h2 className="section__title">
                The progress bar tells the truth.
              </h2>
              <p className="section__lede">
                The ETA is the median of the last 10 completed runs of that same
                workflow, not the last one — so a single fast failure
                doesn&apos;t poison the estimate. Three states, no invented
                numbers.
              </p>
            </div>
          </Reveal>

          <Reveal delay={90}>
            <ProgressStates />
          </Reveal>
        </section>

        {/* ------------------------------------------------------------ logs */}
        <section className={`wrap section ${styles.split}`} id="logs">
          <Reveal className={styles.splitCopy}>
            <span className="eyebrow">Failure output</span>
            <h2 className="section__title">
              The log is already there when it breaks.
            </h2>
            <p className="section__lede">
              Expand a failed run and Runbar fetches the tail of its log inline —
              no browser tab, no hunting through a job matrix for the step that
              actually failed. Errors and warnings are coloured as they stream.
            </p>
            <p className={styles.splitNote}>
              Running builds stream their output live in the same place. One
              click copies the whole tail to your clipboard — try the button.
            </p>
          </Reveal>

          <Reveal className={styles.splitVisual} delay={90}>
            <FailureLog />
          </Reveal>
        </section>

        {/* ------------------------------------------------------- discovery */}
        <section className={`wrap section`} id="discovery">
          <Reveal>
            <div className="section__head">
              <span className="eyebrow">Zero manual repo configuration</span>
              <h2 className="section__title">
                You can exclude repos. You are never asked to add one.
              </h2>
              <p className="section__lede">
                Two sources, unioned and deduped, refreshed on launch and every
                ~30 minutes.
              </p>
            </div>
          </Reveal>

          <Reveal delay={90}>
            <RepoScan />
          </Reveal>

          <Reveal delay={140}>
            <div className={styles.sources}>
              <article className={styles.source}>
                <span className={`mono ${styles.sourceIndex}`}>01</span>
                <h3 className={styles.sourceTitle}>Your code folder</h3>
                <p className={styles.sourceBody}>
                  Walked to depth 4, for anything with a{" "}
                  <code className={styles.code}>.git</code> and at least one{" "}
                  <code className={styles.code}>
                    .github/workflows/*.y&#123;a,&#125;ml
                  </code>
                  . The presence of{" "}
                  <code className={styles.code}>.github/</code> alone
                  isn&apos;t enough — that directory also holds issue templates
                  and <code className={styles.code}>dependabot.yml</code>, which
                  don&apos;t imply Actions.
                </p>
              </article>
              <article className={styles.source}>
                <span className={`mono ${styles.sourceIndex}`}>02</span>
                <h3 className={styles.sourceTitle}>Your GitHub account</h3>
                <p className={styles.sourceBody}>
                  <code className={styles.code}>
                    GET /user/repos?sort=pushed
                  </code>
                  , top 30, as a safety net for repos you care about but
                  haven&apos;t cloned.
                </p>
              </article>
            </div>
          </Reveal>
        </section>

        {/* ---------------------------------------------------- integrations */}
        <section className={`wrap section`} id="integrations">
          <Reveal>
            <div className="section__head">
              <span className="eyebrow">Integrations</span>
              <h2 className="section__title">
                Every pipeline in one menu bar.
              </h2>
              <p className="section__lede">
                Connect any combination — runs from all of them land in the same
                list, sorted by what&apos;s happening now.
              </p>
            </div>
          </Reveal>

          <Reveal delay={90}>
            <Integrations />
          </Reveal>
        </section>

        {/* --------------------------------------------------------- privacy */}
        <section className={`wrap section`} id="privacy">
          <Reveal>
            <div className="section__head">
              <span className="eyebrow">Privacy and access</span>
              <h2 className="section__title">Read-only. Always.</h2>
              <p className="section__lede">
                No backend, no relay, no telemetry, no analytics, no account.
                One app bundle talking directly to the providers you connect.
              </p>
            </div>
          </Reveal>

          <div className={styles.privacyGrid}>
            <Reveal delay={90}>
              <ScopeList />
            </Reveal>
            <Reveal delay={140}>
              <ConditionalRequest />
            </Reveal>
          </div>

          <Reveal delay={180}>
            <div className={styles.privacyNotes}>
              <article className={styles.privacyCard}>
                <h3 className={styles.privacyTitle}>Credentials</h3>
                <p className={styles.privacyBody}>
                  Live in the macOS Keychain. Never in{" "}
                  <code className={styles.code}>UserDefaults</code>, a plist, a
                  file, or a log line.
                </p>
              </article>
              <article className={styles.privacyCard}>
                <h3 className={styles.privacyTitle}>Updates</h3>
                <p className={styles.privacyBody}>
                  Downloaded from GitHub Releases and verified against a signed
                  Sparkle appcast before anything is installed.
                </p>
              </article>
              <article className={styles.privacyCard}>
                <h3 className={styles.privacyTitle}>Source</h3>
                <p className={styles.privacyBody}>
                  MIT licensed and buildable from a single{" "}
                  <code className={styles.code}>./bootstrap.sh</code>, so none
                  of the above has to be taken on trust.
                </p>
              </article>
            </div>
          </Reveal>
        </section>

        {/* ------------------------------------------------------------- cta */}
        <section className={`wrap section ${styles.cta}`}>
          <DotMatrix size={54} />
          <h2 className={styles.ctaTitle}>Sign in, point it at your code.</h2>
          <p className={styles.ctaLede}>
            Requires macOS 14 or later. Free and open source under the MIT
            license.
          </p>
          <div className={styles.actions}>
            <a className={styles.download} href={release.downloadUrl}>
              Download
              {release.version ? ` v${release.version}` : ""}
            </a>
            <a className={styles.secondary} href={RELEASES_URL}>
              All releases
            </a>
          </div>
        </section>
      </main>

      <footer className={styles.footer}>
        <div className={`wrap ${styles.footerInner}`}>
          <span className={`mono ${styles.footerNote}`}>
            Runbar — built by{" "}
            <a className={styles.footerLink} href="https://markoradak.com">
              Marko Radak
            </a>
          </span>
          <div className={styles.footerLinks}>
            <a className={styles.footerLink} href={REPO_URL}>
              Source
            </a>
            <a className={styles.footerLink} href={RELEASES_URL}>
              Releases
            </a>
            <a
              className={styles.footerLink}
              href={`${REPO_URL}/blob/main/LICENSE`}
            >
              MIT
            </a>
          </div>
        </div>
      </footer>
    </>
  );
}
