import type { NextConfig } from "next";

const config: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,

  /*
   * app/opengraph-image.tsx reads its subsetted fonts off disk. Nothing
   * `import`s them, so tracing can't see them — without this the card would
   * render fontless on any deploy that produces it at runtime rather than
   * baking it at build time.
   */
  outputFileTracingIncludes: {
    "/opengraph-image": ["./assets/fonts/**"],
  },
};

export default config;
