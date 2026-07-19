import { createHash, timingSafeEqual } from "node:crypto";
import { revalidateTag } from "next/cache";
import { RELEASE_TAG } from "@/lib/release";

// timingSafeEqual is Node-only, and the secret must never reach the client.
export const runtime = "nodejs";

/**
 * Compares in constant time. Both sides are hashed first so the comparison is
 * over fixed-width digests: that keeps the secret's length from leaking and
 * stops `timingSafeEqual` throwing on mismatched lengths.
 */
function matchesSecret(provided: string | null, expected: string | undefined): boolean {
  // Fail closed. Without this, an unset REVALIDATE_SECRET plus a missing
  // header would compare two empty values and leave the endpoint open.
  if (!provided || !expected) return false;
  const digest = (value: string) => createHash("sha256").update(value).digest();
  return timingSafeEqual(digest(provided), digest(expected));
}

/**
 * Drops the cached GitHub release lookup so the version badge and download
 * link pick up a new release immediately. Called by the `Refresh site release
 * cache` step in .github/workflows/release.yml once the release is published.
 */
export async function POST(request: Request): Promise<Response> {
  if (!matchesSecret(request.headers.get("x-revalidate-secret"), process.env.REVALIDATE_SECRET)) {
    // Deliberately terse: no hint about whether the secret is configured.
    return new Response("Unauthorized", { status: 401 });
  }

  // Next 16 requires a cache-life profile alongside the tag. `expire: 0` is
  // the immediate-purge path — anything else would only mark the entry stale
  // and keep serving the old release until the next background revalidate.
  revalidateTag(RELEASE_TAG, { expire: 0 });
  return Response.json({ revalidated: true, tag: RELEASE_TAG });
}
