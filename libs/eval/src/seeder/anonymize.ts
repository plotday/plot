import { createHash } from "node:crypto";

const NAMESPACE = "plotday-eval-anonymize-v1";

/** Deterministic short hash for stable PII tokens. */
export function hashShort(input: string, length = 8): string {
  return createHash("sha256").update(`${NAMESPACE}:${input}`).digest("hex").slice(0, length);
}

/** Replace an email with a synthetic but stable address. */
export function anonymizeEmail(email: string | null): string | null {
  if (!email) return null;
  return `c-${hashShort(email, 12)}@example.test`;
}

/** Replace a personal name with a stable opaque token. */
export function anonymizeName(name: string | null): string | null {
  if (!name) return null;
  return `Person ${hashShort(name, 6)}`;
}
