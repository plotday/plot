/**
 * Verify a Unipile **v2** webhook signature.
 *
 * v2 signs every delivery with HMAC SHA-256 (NOT a custom header — that was v1).
 * The signature arrives in the `unipile-signature` header as:
 *
 *   unipile-signature: t=<unix-seconds>,v0=<hmac-sha256-hex>
 *
 * The signed payload is `` `${t}.${rawBody}` `` and the HMAC key is the
 * per-endpoint secret shown in the Unipile dashboard (stored as
 * `UNIPILE_WEBHOOK_SECRET`). Verify against the RAW body exactly as received —
 * never parse-then-reserialize, or whitespace/key-order changes break the MAC.
 *
 * See https://developer.unipile.com/v2.0/docs/configure-a-webhook
 */
export async function verifyUnipileSignature(
  signatureHeader: string | undefined | null,
  rawBody: string,
  secret: string
): Promise<boolean> {
  if (!signatureHeader || !secret) return false;

  const parts: Record<string, string> = {};
  for (const seg of signatureHeader.split(",")) {
    const eq = seg.indexOf("=");
    if (eq === -1) continue;
    parts[seg.slice(0, eq).trim()] = seg.slice(eq + 1).trim();
  }
  const t = parts.t;
  const v0 = parts.v0;
  if (!t || !v0) return false;

  const expected = await hmacSha256Hex(secret, `${t}.${rawBody}`);
  return timingSafeEqualHex(expected, v0);
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant-time comparison of two equal-length hex strings. */
function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
