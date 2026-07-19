const REPO = "markoradak/runbar";

export const REPO_URL = `https://github.com/${REPO}`;
export const RELEASES_URL = `${REPO_URL}/releases`;

/**
 * Cache tag for the latest-release lookup. The release workflow POSTs to
 * `/api/revalidate` after publishing, which invalidates this tag so the
 * download link points at the new asset immediately rather than after the
 * hourly revalidate below. Tagged rather than `revalidatePath("/")` so any
 * future page using `getLatestRelease` is covered too.
 */
export const RELEASE_TAG = "latest-release";

export type Release = {
  /** Display version without the leading `v`, e.g. "0.1.6". */
  version: string | null;
  /** Direct link to the .zip asset, or the releases page if it can't be resolved. */
  downloadUrl: string;
  /** Asset size in bytes, when known. */
  size: number | null;
};

type GitHubAsset = {
  name: string;
  browser_download_url: string;
  size: number;
};

type GitHubRelease = {
  tag_name: string;
  assets: GitHubAsset[];
};

const FALLBACK: Release = {
  version: null,
  downloadUrl: RELEASES_URL,
  size: null,
};

/**
 * The release workflow publishes a *versioned* asset name (`Runbar-0.1.6.zip`,
 * see .github/workflows/release.yml), so there is no stable
 * `releases/latest/download/<name>` URL to hardcode — the exact filename has to
 * be read back from the API.
 *
 * Revalidates hourly, and on demand via `RELEASE_TAG` the moment a release
 * publishes. Unauthenticated GitHub API calls are limited to 60/hr per IP;
 * caching keeps us far under it, and any failure degrades to a plain link to
 * the releases page rather than breaking the page.
 */
export async function getLatestRelease(): Promise<Release> {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases/latest`,
      {
        headers: {
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
        },
        next: { revalidate: 3600, tags: [RELEASE_TAG] },
      },
    );

    if (!res.ok) return FALLBACK;

    const data = (await res.json()) as GitHubRelease;
    const asset = data.assets?.find((a) => a.name.endsWith(".zip"));

    return {
      version: data.tag_name?.replace(/^v/, "") ?? null,
      downloadUrl: asset?.browser_download_url ?? RELEASES_URL,
      size: asset?.size ?? null,
    };
  } catch {
    return FALLBACK;
  }
}

export function formatSize(bytes: number | null): string | null {
  if (!bytes) return null;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}
