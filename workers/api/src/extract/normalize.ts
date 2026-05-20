// Tracking params we strip during normalization. Two URLs that differ only
// by these should dedupe to the same extracted_url row.
const STRIP_PARAMS = new Set([
  "fbclid",
  "gclid",
  "mc_eid",
  "mc_cid",
  "_ga",
  "_gl",
  "ref_src",
]);

function isTrackingParam(name: string): boolean {
  const lower = name.toLowerCase();
  return lower.startsWith("utm_") || STRIP_PARAMS.has(lower);
}

/**
 * Canonicalize a URL for deduplication. Throws if `raw` is not a valid URL.
 *
 * Conservative form: lowercase host, strip default ports and fragment, drop
 * known tracking params. Path case and query order are preserved (some
 * servers serve different content based on case or param ordering).
 */
export function normalizeUrl(raw: string): string {
  const u = new URL(raw);
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    throw new Error(`unsupported URL protocol: ${u.protocol}`);
  }

  u.hostname = u.hostname.toLowerCase();
  if (
    (u.protocol === "http:" && u.port === "80") ||
    (u.protocol === "https:" && u.port === "443")
  ) {
    u.port = "";
  }
  u.hash = "";

  const filtered: [string, string][] = [];
  for (const [k, v] of u.searchParams) {
    if (!isTrackingParam(k)) filtered.push([k, v]);
  }
  // Rebuild the query string preserving order.
  u.search = "";
  for (const [k, v] of filtered) {
    u.searchParams.append(k, v);
  }

  return u.toString();
}

/**
 * SHA-256 of the normalized URL, returned as lowercase hex. Used as both
 * the dedup key in `extracted_url.url_hash` and the R2 object key stem.
 */
export async function hashUrl(normalized: string): Promise<string> {
  const bytes = new TextEncoder().encode(normalized);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const view = new Uint8Array(digest);
  let hex = "";
  for (let i = 0; i < view.length; i++) {
    hex += view[i].toString(16).padStart(2, "0");
  }
  return hex;
}
