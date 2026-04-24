/**
 * Compute the sync baseline hash for note content as seen by a connector.
 *
 * The hash distinguishes "connector re-listed unchanged content" (preserve
 * Plot's stored content, which may be richer markdown) from "external
 * system has new content" (overwrite with incoming). We hash the content
 * string only — contentType is intentionally excluded so sync-in and
 * write-back don't have to agree on a contentType label for the same
 * underlying bytes (e.g. a connector that writes plain text and reads back
 * plain text always hashes consistently regardless of whether either side
 * labels it "text" vs. relies on the NewNote default).
 *
 * SHA-256 hex (64 chars) is stored verbatim in `note.external_content_hash`.
 */
export async function hashExternalContent(content: string): Promise<string> {
  const data = new TextEncoder().encode(content);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}
