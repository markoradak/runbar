import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";

/*
 * The social card: the hero, rendered as a still.
 *
 * Copy left, the menu-bar panel right, on the same faint engineering grid —
 * so an unfurled link and the page a click later are recognisably one thing.
 * The panel is drawn at its real metrics (420px wide, the 12.5/10.5/9.5 type
 * ladder, the 20/10/9/7 radii) rather than a scaled-up impression of it, which
 * is why the numbers below match panel.module.css line for line. Its type is
 * genuinely tiny at feed size — it reads as UI texture there, and as the actual
 * product to anyone who opens the image.
 *
 * Nothing here carries a version or a release size. Social platforms cache
 * og:image hard, and this PNG is baked once at build, so anything that changes
 * per release would be a lie by the second release after a crawl.
 */

export const alt =
  "Runbar — a native macOS menu-bar monitor for GitHub Actions, Vercel, and Cloudflare Pages";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/* ----------------------------------------------------------------- tokens -- */

/*
 * globals.css, light theme. Satori has no custom properties and no relative
 * colour syntax, so `rgb(from var(--blue) r g b / 0.12)` has to be written out
 * as the literal it resolves to.
 */
const WASH = "#faf8f4";
const GREEN = "#34c759";
const RED = "#ff3b30";
const BLUE = "#007aff";

/** `--primary` (26 24 20) at an arbitrary opacity — the overlay ladder. */
const ink = (alpha: number) => `rgba(26, 24, 20, ${alpha})`;
const blue = (alpha: number) => `rgba(0, 122, 255, ${alpha})`;
const red = (alpha: number) => `rgba(255, 59, 48, ${alpha})`;

const TEXT = ink(1);
const TEXT_SECONDARY = ink(0.55);
const TEXT_TERTIARY = ink(0.38);
const BORDER = ink(0.1);
const BORDER_STRONG = ink(0.16);
const SURFACE = "rgba(255, 255, 255, 0.5)";
const FILL_SUBTLE = ink(0.035);
const FILL = ink(0.05);
const FILL_HOVER = ink(0.08);

const SANS = "Inter";
const MONO = "JetBrains Mono";

/*
 * Satori has no access to the system stack the site draws with (SF Pro / SF
 * Mono are macOS-only and not redistributable), so the card ships the two
 * fallbacks already declared in --font-sans / --font-mono, subsetted to the
 * characters used here — ~30KB each instead of ~300KB.
 *
 * Read off disk rather than through the `new URL(..., import.meta.url)` + fetch
 * pattern in the Next docs: under Turbopack that resolves to a `file:` URL, and
 * undici's fetch rejects those outright. This route renders at build time, where
 * cwd is the project root; next.config.ts traces the directory so the fonts are
 * also there if a deploy ever renders it at runtime.
 */
const font = (file: string) =>
  readFile(join(process.cwd(), "assets", "fonts", file));

/* ------------------------------------------------------------------ icons -- */

/** Provider marks, transcribed from components/demo/ProviderIcon.tsx. */
const GITHUB_PATH =
  "M12 .5A11.5 11.5 0 0 0 .5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.56-.29-5.25-1.28-5.25-5.7 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.79 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.12 3.05.74.81 1.18 1.84 1.18 3.1 0 4.43-2.69 5.4-5.26 5.69.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12 11.5 11.5 0 0 0 12 .5Z";

const BRANCH_PATH =
  "M6 3v12m0 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm12-9a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 0c0 4-4 5-6 5";
const BOLT_PATH = "M13 2 4 14h6l-1 8 9-12h-6l1-8Z";
const REFRESH_PATH = "M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6";
const SETTINGS_PATH =
  "M12 15.5A3.5 3.5 0 1 0 12 8.5a3.5 3.5 0 0 0 0 7Zm7.4-2.6.1-.9-.1-.9 1.9-1.5-1.9-3.2-2.3.8a7 7 0 0 0-1.6-.9L15.1 2h-3.7l-.4 2.4a7 7 0 0 0-1.6.9l-2.3-.8-1.9 3.2L7.1 9.2a7.4 7.4 0 0 0 0 1.8l-1.9 1.5 1.9 3.2 2.3-.8c.5.4 1 .7 1.6.9l.4 2.4h3.7l.4-2.4c.6-.2 1.1-.5 1.6-.9l2.3.8 1.9-3.2-1.9-1.5Z";
const POWER_PATH = "M12 3v9m6.4-6.4a9 9 0 1 1-12.8 0";
const CHEVRON_PATH = "m5 9 7 7 7-7";
const DOWNLOAD_PATH =
  "M8 1.5v9m0 0L4.5 7M8 10.5 11.5 7M2 12.5v1a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-1";

function Stroke({
  d,
  size,
  color,
  width = 2.2,
  viewBox = "0 0 24 24",
}: {
  d: string;
  size: number;
  color: string;
  width?: number;
  viewBox?: string;
}) {
  return (
    <svg width={size} height={size} viewBox={viewBox}>
      <path
        d={d}
        stroke={color}
        strokeWidth={width}
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function Filled({
  d,
  size,
  color,
}: {
  d: string;
  size: number;
  color: string;
}) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d={d} fill={color} />
    </svg>
  );
}

/* ------------------------------------------------------------------ parts -- */

/**
 * The 2×3 mark from favicon.svg, rebuilt as divs — Satori's SVG support is
 * partial and this is six circles. Dot diameter is 25.76u against a 47.24u
 * centre-to-centre spacing in the source artwork, so the edge gap is 0.83× the
 * diameter; deriving it keeps the mark on-model at any size.
 */
function DotMark({
  dot,
  tint,
}: {
  dot: number;
  /** The mark inherits `color` from its tile, so the tile's accent tints it. */
  tint: (alpha: number) => string;
}) {
  const gap = dot * 0.83;
  // Column-major, matching BRAND_OPACITY in components/DotMatrix.tsx.
  const columns = [
    [0.85, 0.7, 0.66],
    [1, 0.25, 0.4],
  ];

  return (
    <div style={{ display: "flex", gap }}>
      {columns.map((column, i) => (
        <div key={i} style={{ display: "flex", flexDirection: "column", gap }}>
          {column.map((opacity, j) => (
            <div
              key={j}
              style={{
                width: dot,
                height: dot,
                borderRadius: dot,
                background: tint(opacity),
              }}
            />
          ))}
        </div>
      ))}
    </div>
  );
}

/** ProviderIconTile: radius size×0.28, 5.5% fill, 9% border, mark at size×0.56. */
function ProviderTile({
  provider,
  size: s,
  badge,
}: {
  provider: "github" | "vercel";
  size: number;
  badge?: "success" | "failure";
}) {
  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        flex: "none",
        width: s,
        height: s,
        borderRadius: s * 0.28,
        background: ink(0.055),
        border: `1px solid ${ink(0.09)}`,
      }}
    >
      {provider === "github" ? (
        <Filled d={GITHUB_PATH} size={s * 0.56} color={ink(0.88)} />
      ) : (
        <Filled d="M12 2 23 21H1L12 2Z" size={s * 0.56} color={ink(0.88)} />
      )}
      {badge ? (
        <div
          style={{
            position: "absolute",
            right: -2,
            bottom: -2,
            width: 7,
            height: 7,
            borderRadius: 7,
            background: badge === "success" ? GREEN : RED,
            boxShadow: `0 0 0 1.5px ${WASH}`,
          }}
        />
      ) : null}
    </div>
  );
}

/** SectionHeader: title, rule, count badge. */
function SectionHeader({
  title,
  count,
  accent,
}: {
  title: string;
  count: number;
  accent: "blue" | "muted";
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <span
        style={{
          fontFamily: MONO,
          fontSize: 9.5,
          fontWeight: 600,
          letterSpacing: 1.6,
          color: TEXT_SECONDARY,
        }}
      >
        {title}
      </span>
      <div style={{ display: "flex", flex: 1, height: 1, background: BORDER }} />
      <span
        style={{
          fontFamily: MONO,
          fontSize: 10,
          fontWeight: 600,
          padding: "1px 6px",
          borderRadius: 4,
          color: accent === "blue" ? BLUE : TEXT_SECONDARY,
          background: accent === "blue" ? blue(0.12) : FILL_HOVER,
        }}
      >
        {count}
      </span>
    </div>
  );
}

/** MetaChip: the branch / event chips under a running card. */
function MetaChip({ icon, text }: { icon: "branch" | "bolt"; text: string }) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 4,
        padding: "3.5px 7px",
        border: `1px solid ${BORDER}`,
        borderRadius: 5,
        background: FILL,
        fontFamily: MONO,
        fontSize: 9.5,
        color: TEXT_SECONDARY,
      }}
    >
      {icon === "branch" ? (
        <Stroke d={BRANCH_PATH} size={9} color={TEXT_SECONDARY} />
      ) : (
        <Filled d={BOLT_PATH} size={9} color={TEXT_SECONDARY} />
      )}
      <span>{text}</span>
    </div>
  );
}

/** A completed run in the RECENT list. */
function RecentRow({
  workflow,
  repo,
  conclusion,
  duration,
  when,
  head,
}: {
  workflow: string;
  repo: string;
  conclusion: "success" | "failure";
  duration: string;
  when: string;
  head?: boolean;
}) {
  const failed = conclusion === "failure";

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "9px 10px",
        borderRadius: 9,
        border: `1px solid ${
          failed ? red(0.25) : head ? blue(0.35) : BORDER
        }`,
        background: failed ? red(0.07) : SURFACE,
      }}
    >
      <ProviderTile
        provider={repo.endsWith("/site") ? "vercel" : "github"}
        size={26}
        badge={conclusion}
      />

      <div
        style={{ display: "flex", flexDirection: "column", gap: 2, flex: 1 }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span
            style={{ fontSize: 12.5, fontWeight: 600, letterSpacing: "-0.01em" }}
          >
            {workflow}
          </span>
          {head ? (
            <span
              style={{
                padding: "2px 5px",
                borderRadius: 4,
                background: blue(0.14),
                color: BLUE,
                fontFamily: MONO,
                fontSize: 8.5,
                fontWeight: 600,
                letterSpacing: 0.5,
              }}
            >
              HEAD
            </span>
          ) : null}
          <span
            style={{
              marginLeft: "auto",
              fontFamily: MONO,
              fontSize: 9.5,
              color: TEXT_SECONDARY,
            }}
          >
            {when}
          </span>
        </div>

        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            fontFamily: MONO,
            fontSize: 10,
            color: TEXT_SECONDARY,
          }}
        >
          <span>{repo}</span>
          <span>·</span>
          <span style={{ color: failed ? RED : GREEN }}>{conclusion}</span>
          <span>·</span>
          <span>{duration}</span>
          {failed ? (
            <div style={{ display: "flex", marginLeft: "auto" }}>
              <Stroke
                d={CHEVRON_PATH}
                size={10}
                color={TEXT_SECONDARY}
                width={2.6}
              />
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/** The three glyph buttons in the panel footer. */
function FooterButton({ d }: { d: string }) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        width: 28,
        height: 28,
        border: `1px solid ${BORDER}`,
        borderRadius: 7,
        background: FILL,
      }}
    >
      <Stroke d={d} size={12} color={TEXT_SECONDARY} width={2} />
    </div>
  );
}

/* -------------------------------------------------------------------- card -- */

export default async function Image() {
  const [regular, semibold, mono] = await Promise.all([
    font("Inter-Regular.ttf"),
    font("Inter-SemiBold.ttf"),
    font("JetBrainsMono-Medium.ttf"),
  ]);

  return new ImageResponse(
    (
      <div
        style={{
          position: "relative",
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          padding: "0 58px",
          background: WASH,
          color: TEXT,
          fontFamily: SANS,
        }}
      >
        {/*
          The hero's engineering grid, same 56px pitch. On the page it's masked
          to an ellipse so it fades toward the edges; Satori implements neither
          mask-image nor (reliably) a percentage-radius radial gradient to fake
          one with, so it runs flat at a lower contrast instead — the same
          texture, and no hard cut-off to give the approximation away.
        */}
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            backgroundImage: `linear-gradient(${ink(
              0.055,
            )} 1px, transparent 1px), linear-gradient(90deg, ${ink(
              0.055,
            )} 1px, transparent 1px)`,
            backgroundSize: "56px 56px",
          }}
        />

        {/* ---------------------------------------------------------- copy -- */}
        <div style={{ display: "flex", flexDirection: "column", width: 590 }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 5,
              alignSelf: "flex-start",
              padding: "5px 9px",
              border: `1px solid ${BORDER}`,
              borderRadius: 999,
              background: FILL,
              fontFamily: MONO,
              fontSize: 10.5,
            }}
          >
            <div
              style={{ width: 6, height: 6, borderRadius: 6, background: GREEN }}
            />
            <span>macOS 14+ · MIT licensed</span>
          </div>

          <div
            style={{
              display: "flex",
              flexDirection: "column",
              marginTop: 20,
              fontSize: 54,
              fontWeight: 600,
              letterSpacing: "-0.03em",
              lineHeight: 1.15,
            }}
          >
            <span>Your CI, one second</span>
            <div style={{ display: "flex", alignItems: "center" }}>
              {/*
                Each span is its own flex item, so a trailing space inside one is
                trimmed away — the word gap has to be a margin.
              */}
              <span style={{ marginRight: 15 }}>after</span>
              <span
                style={{
                  padding: "3px 10px",
                  border: `1px solid ${BORDER}`,
                  borderRadius: 8,
                  background: FILL,
                  fontFamily: MONO,
                  fontSize: 44,
                  fontWeight: 400,
                  letterSpacing: "-0.02em",
                }}
              >
                git push
              </span>
              <span>.</span>
            </div>
          </div>

          <div
            style={{
              display: "flex",
              marginTop: 22,
              maxWidth: 520,
              fontSize: 18.5,
              lineHeight: 1.55,
              color: TEXT_SECONDARY,
            }}
          >
            A native macOS menu-bar monitor for GitHub Actions, Vercel, and
            Cloudflare Pages — across every repo you already have checked out.
          </div>

          <div style={{ display: "flex", gap: 10, marginTop: 30 }}>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                padding: "11px 20px",
                borderRadius: 10,
                background: TEXT,
                color: WASH,
                fontSize: 14.5,
                fontWeight: 600,
              }}
            >
              <Stroke
                d={DOWNLOAD_PATH}
                size={15}
                color={WASH}
                width={1.6}
                viewBox="0 0 16 16"
              />
              <span>Download for macOS</span>
            </div>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                padding: "11px 18px",
                border: `1px solid ${BORDER_STRONG}`,
                borderRadius: 10,
                background: FILL_SUBTLE,
                fontSize: 14.5,
              }}
            >
              View source
            </div>
          </div>

          <div
            style={{
              display: "flex",
              marginTop: 16,
              fontFamily: MONO,
              fontSize: 11.5,
              color: TEXT_TERTIARY,
            }}
          >
            Apple silicon &amp; Intel · updates via Sparkle · no telemetry
          </div>
        </div>

        {/* --------------------------------------------------------- panel -- */}
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            width: 420,
            marginLeft: "auto",
            border: `1px solid ${BORDER}`,
            borderRadius: 20,
            background: WASH,
            boxShadow:
              "0 8px 18px rgba(0, 0, 0, 0.22), 0 1px 2px rgba(0, 0, 0, 0.08)",
          }}
        >
          {/* header */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 11,
              padding: "12px 14px",
              background: SURFACE,
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                width: 36,
                height: 36,
                borderRadius: 10,
                border: `1px solid ${BORDER}`,
                background: blue(0.1),
                boxShadow: `inset 0 0 0 1px ${blue(0.25)}`,
              }}
            >
              {/* DotMatrix size 20 — dot diameter is 0.1717 of the box. */}
              <DotMark dot={20 * 0.1717} tint={blue} />
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              <span
                style={{
                  fontFamily: MONO,
                  fontSize: 13,
                  fontWeight: 600,
                  letterSpacing: "-0.02em",
                }}
              >
                runbar
              </span>
              <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
                {/* The ❯ of the status line: U+276F is in neither shipped font,
                    so it is drawn rather than typed. */}
                <Stroke d="m9 6 6 6-6 6" size={8} color={BLUE} width={3} />
                <span
                  style={{
                    fontFamily: MONO,
                    fontSize: 10,
                    color: TEXT_SECONDARY,
                  }}
                >
                  1 running
                </span>
              </div>
            </div>

            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 5,
                marginLeft: "auto",
                padding: "5px 9px",
                border: `1px solid ${BORDER}`,
                borderRadius: 999,
                background: FILL,
                fontFamily: MONO,
                fontSize: 10.5,
              }}
            >
              <div
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: 6,
                  background: GREEN,
                }}
              />
              <span>@markoradak</span>
            </div>
          </div>

          <div style={{ display: "flex", height: 1, background: BORDER }} />

          {/* content */}
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              gap: 18,
              padding: 14,
            }}
          >
            {/* running */}
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              <SectionHeader title="RUNNING" count={1} accent="blue" />

              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  gap: 10,
                  padding: 12,
                  border: `1px solid ${BORDER}`,
                  borderRadius: 10,
                  background: SURFACE,
                }}
              >
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <ProviderTile provider="github" size={28} />
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: 2,
                      flex: 1,
                    }}
                  >
                    <div
                      style={{ display: "flex", alignItems: "center", gap: 6 }}
                    >
                      <span
                        style={{
                          fontSize: 12.5,
                          fontWeight: 600,
                          letterSpacing: "-0.01em",
                        }}
                      >
                        CI
                      </span>
                      <span
                        style={{
                          padding: "1px 5px",
                          border: `1px solid ${BORDER}`,
                          borderRadius: 4,
                          background: FILL,
                          fontFamily: MONO,
                          fontSize: 8.5,
                          color: TEXT_TERTIARY,
                        }}
                      >
                        workflow
                      </span>
                    </div>
                    <span
                      style={{
                        fontFamily: MONO,
                        fontSize: 10.5,
                        color: TEXT_SECONDARY,
                      }}
                    >
                      markoradak/runbar
                    </span>
                  </div>
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 5,
                      padding: "4px 8px",
                      borderRadius: 999,
                      background: blue(0.12),
                      color: BLUE,
                      fontFamily: MONO,
                      fontSize: 11.5,
                      fontWeight: 600,
                    }}
                  >
                    <div
                      style={{
                        width: 5,
                        height: 5,
                        borderRadius: 5,
                        background: BLUE,
                      }}
                    />
                    <span>2m 12s</span>
                  </div>
                </div>

                <div style={{ display: "flex", gap: 6 }}>
                  <MetaChip icon="branch" text="main" />
                  <MetaChip icon="bolt" text="push" />
                </div>

                <div
                  style={{ display: "flex", flexDirection: "column", gap: 5 }}
                >
                  <div
                    style={{
                      display: "flex",
                      height: 4,
                      borderRadius: 999,
                      background: ink(0.08),
                    }}
                  >
                    <div
                      style={{
                        width: "98%",
                        borderRadius: 999,
                        // LinearGradient([color.opacity(0.65), color])
                        background: `linear-gradient(90deg, ${blue(
                          0.65,
                        )}, ${BLUE})`,
                      }}
                    />
                  </div>
                  <div
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      fontFamily: MONO,
                      fontSize: 9.5,
                      color: TEXT_SECONDARY,
                    }}
                  >
                    <span>median 2m 14s</span>
                    <span>~2s left</span>
                  </div>
                </div>
              </div>
            </div>

            {/* recent */}
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              <SectionHeader title="RECENT" count={3} accent="muted" />
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <RecentRow
                  workflow="Release"
                  repo="markoradak/shiftover"
                  conclusion="success"
                  duration="1m 4s"
                  when="4m ago"
                  head
                />
                <RecentRow
                  workflow="Tests"
                  repo="markoradak/runbar"
                  conclusion="failure"
                  duration="47s"
                  when="17m ago"
                />
                <RecentRow
                  workflow="Preview"
                  repo="markoradak/site"
                  conclusion="success"
                  duration="38s"
                  when="40m ago"
                />
              </div>
            </div>
          </div>

          <div style={{ display: "flex", height: 1, background: BORDER }} />

          {/* footer */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              padding: "10px 14px",
              background: SURFACE,
            }}
          >
            <span
              style={{
                fontFamily: MONO,
                fontSize: 9.5,
                color: TEXT_SECONDARY,
              }}
            >
              synced 8s ago
            </span>
            <div style={{ display: "flex", gap: 6, marginLeft: "auto" }}>
              <FooterButton d={REFRESH_PATH} />
              <FooterButton d={SETTINGS_PATH} />
              <FooterButton d={POWER_PATH} />
            </div>
          </div>
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [
        { name: SANS, data: regular, weight: 400, style: "normal" },
        { name: SANS, data: semibold, weight: 600, style: "normal" },
        { name: MONO, data: mono, weight: 500, style: "normal" },
      ],
    },
  );
}
