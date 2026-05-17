import { createHash } from "node:crypto";

const NAMESPACE = "plotday-eval-anonymize-v1";

/**
 * Deterministically remap a value to a UUID v4-shaped string. Same input
 * always yields the same output across runs (within a namespace).
 */
export function remapUuid(originalUuid: string, namespace = NAMESPACE): string {
  const h = createHash("sha256").update(`${namespace}:${originalUuid}`).digest("hex");
  return [
    h.slice(0, 8),
    h.slice(8, 12),
    "4" + h.slice(13, 16),
    "a" + h.slice(17, 20),
    h.slice(20, 32),
  ].join("-");
}

/** Deterministic short hash for opaque strings (titles, names). */
export function hashShort(input: string, length = 8): string {
  return createHash("sha256").update(`${NAMESPACE}:${input}`).digest("hex").slice(0, length);
}

/** Replace a title with a stable opaque token. */
export function anonymizeTitle(title: string | null): string {
  if (!title) return "(untitled)";
  return `t-${hashShort(title, 10)}`;
}

/** Replace an email with a synthetic but stable address. */
export function anonymizeEmail(email: string | null): string | null {
  if (!email) return null;
  return `c-${hashShort(email, 12)}@example.test`;
}

/**
 * Remap a small int (e.g., channel id) to a stable but compact remapping.
 * We hash and modulo into a wide-ish space to avoid collisions in practice.
 */
export function remapInt(original: number, namespace = NAMESPACE): number {
  const h = createHash("sha256").update(`${namespace}:int:${original}`).digest();
  // Pack first 4 bytes as unsigned, then bound to a 6-digit space for readability.
  const n = h.readUInt32BE(0);
  return 100000 + (n % 900000);
}
