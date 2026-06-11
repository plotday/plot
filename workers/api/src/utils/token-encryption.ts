/**
 * Application-level encryption for connection auth tokens stored in the
 * Storage Durable Object. Applied transparently by Storage.get/set for keys
 * under the `auth_token:` prefix, on top of Cloudflare's infrastructure
 * encryption at rest.
 *
 * Stored envelope: {"__enc":1,"iv":"<b64>","data":"<b64>"}. Legacy values are
 * SuperJSON/JSON strings that can never start with `{"__enc"`, so detection
 * is unambiguous and pre-existing plaintext tokens keep working; they become
 * encrypted the next time they are written (e.g. on token refresh).
 */
import { decrypt, encrypt } from "./encryption";

export const TOKEN_KEY_PREFIX = "auth_token:";

export function isTokenKey(key: string): boolean {
  return key.startsWith(TOKEN_KEY_PREFIX);
}

type TokenEnvelope = { __enc: 1; iv: string; data: string };

function parseEnvelope(raw: string): TokenEnvelope | null {
  if (!raw.startsWith('{"__enc"')) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<TokenEnvelope>;
    if (
      parsed.__enc === 1 &&
      typeof parsed.iv === "string" &&
      typeof parsed.data === "string"
    ) {
      return parsed as TokenEnvelope;
    }
  } catch {
    // fall through — treat as legacy plaintext
  }
  return null;
}

/**
 * Encrypt a serialized token value for storage. Passthrough when no key is
 * configured so a missing secret degrades to today's behavior instead of
 * breaking auth.
 */
export async function sealTokenValue(
  plaintext: string,
  hexKey: string | undefined
): Promise<string> {
  if (!hexKey) return plaintext;
  const { ciphertext, iv } = await encrypt(plaintext, hexKey);
  const envelope: TokenEnvelope = { __enc: 1, iv, data: ciphertext };
  return JSON.stringify(envelope);
}

/**
 * Decrypt a stored token value.
 * - envelope + key → plaintext (null if decryption fails)
 * - envelope + no key → null (unrecoverable; caller treats as missing)
 * - legacy plaintext → returned unchanged
 */
export async function openTokenValue(
  stored: string,
  hexKey: string | undefined
): Promise<string | null> {
  const envelope = parseEnvelope(stored);
  if (!envelope) return stored;
  if (!hexKey) return null;
  try {
    return await decrypt(envelope.data, envelope.iv, hexKey);
  } catch {
    return null;
  }
}
