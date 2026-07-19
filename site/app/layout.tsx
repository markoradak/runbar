import type { Metadata, Viewport } from "next";
import "./globals.css";

// Set NEXT_PUBLIC_SITE_URL in the Vercel project once the domain is attached;
// this default only affects the absolute URLs in OG/Twitter tags.
const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://runbar.app";

const DESCRIPTION =
  "A native macOS menu-bar monitor for GitHub Actions, Vercel, and Cloudflare Pages — across every repo you already have checked out, with zero manual configuration.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: "Runbar — CI in your menu bar, one second after push",
  description: DESCRIPTION,
  applicationName: "Runbar",
  keywords: [
    "macOS",
    "menu bar",
    "GitHub Actions",
    "CI",
    "Vercel",
    "Cloudflare Pages",
  ],
  openGraph: {
    type: "website",
    url: SITE_URL,
    siteName: "Runbar",
    title: "Runbar — CI in your menu bar, one second after push",
    description: DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    title: "Runbar — CI in your menu bar, one second after push",
    description: DESCRIPTION,
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#faf8f4" },
    { media: "(prefers-color-scheme: dark)", color: "#191814" },
  ],
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  // suppressHydrationWarning below is required, not incidental: the inline
  // script stamps data-theme onto <html> before React hydrates, so the server
  // markup and the client DOM necessarily disagree on that one attribute. It
  // applies only one level deep, so real mismatches inside the tree still
  // surface.
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        {/*
          Applies a stored theme choice before first paint. Without this a
          visitor who picked a theme opposite to their OS setting would see the
          media-query default flash first.
        */}
        <script
          dangerouslySetInnerHTML={{
            __html: `try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.dataset.theme=t}catch(e){}`,
          }}
        />
        {/*
          Scroll reveals start hidden and are un-hidden by an IntersectionObserver.
          Without this, a visitor with JS disabled would get a page whose sections
          never become visible.
        */}
        <noscript>
          <style>{`[data-reveal]{opacity:1!important;transform:none!important}`}</style>
        </noscript>
      </head>
      <body>{children}</body>
    </html>
  );
}
