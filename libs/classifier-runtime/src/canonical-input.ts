import type { Candidate } from "@plotday/classifier";

export type CanonicalContextSnapshot = {
  userId: string;
  /** id + key for every active priority the user has. */
  priorities: { id: string; key: string | null }[];
};

/**
 * Build the byte-deterministic input string used to derive the LLM cache
 * key. The same logical input must serialize to byte-identical bytes
 * between the foreground (workers/api) and background (workers/classify)
 * call sites — otherwise the KV cache is useless.
 *
 * Rules (mirrored by the parity test):
 * - All UUID arrays sorted lexicographically.
 * - Embedding floats rounded to 4 decimal places.
 * - Priority snapshot ordered by id.
 * - Title/notes are NOT part of the input (the embedding fingerprints content).
 * - facets serialized with sorted keys so insertion order doesn't matter.
 * - authorContactId and connectionId included so candidates differing only in
 *   those fields (which affect origin/gate scoring) never share a cache key.
 */
export function canonicalInput(
  promptId: string,
  ctx: CanonicalContextSnapshot,
  cand: Candidate
): string {
  return JSON.stringify({
    p: promptId,
    c: {
      userId: ctx.userId,
      topic: cand.topic ?? null,
      contacts: [...(cand.contacts ?? [])].sort(),
      groups: [...(cand.groups ?? [])].sort(),
      embedding: cand.embedding
        ? cand.embedding.map((x: number) => Number(x.toFixed(4)))
        : null,
      facets: cand.facets
        ? Object.fromEntries(
            Object.entries(cand.facets).sort(([a], [b]) => a.localeCompare(b))
          )
        : null,
      authorContactId: cand.authorContactId ?? null,
      connectionId: cand.connectionId ?? null,
      priorities: [...ctx.priorities]
        .sort((a, b) => a.id.localeCompare(b.id))
        .map((p) => ({ id: p.id, key: p.key })),
    },
  });
}

/** Hex sha-256 of a UTF-8 string using WebCrypto. */
export async function sha256Hex(input: string): Promise<string> {
  const buf = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", buf);
  const bytes = new Uint8Array(digest);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i]!.toString(16).padStart(2, "0");
  }
  return out;
}
