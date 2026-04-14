/**
 * Secure options: encrypt/decrypt/mask helpers for twist options marked `secure: true`.
 *
 * Secure options (e.g. API keys) are stored in a separate `secure_option` table
 * with AES-256-GCM encryption, using the same key as AI key encryption.
 * The plaintext never appears in `twist_instance.config`.
 */

import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { OptionsSchema, OptionDef } from "@plotday/twister/options";
import { encrypt, decrypt } from "./encryption";

/** Check if an option def is a secure text field. */
function isSecureText(def: OptionDef): boolean {
  return def.type === "text" && "secure" in def && (def as any).secure === true;
}

/**
 * Process secure options during config save.
 *
 * For each `secure: true` TextDef key in config:
 * - Non-empty string → encrypt and upsert into `secure_option`, replace in config with `true` sentinel
 * - `null` → delete from `secure_option`, keep `null` in config
 * - `true` (sentinel, unchanged) → remove from config update (no-op)
 *
 * @param userId - When provided, stores per-user (individual key). When null, stores shared.
 * Returns cleaned config without secure plaintext values.
 */
export async function saveSecureOptions(
  db: Kysely<DB>,
  encryptionKey: string,
  twistInstanceId: string,
  schema: OptionsSchema,
  config: Record<string, unknown>,
  userId?: string | null
): Promise<Record<string, unknown>> {
  const cleaned = { ...config };

  for (const [key, def] of Object.entries(schema)) {
    if (!isSecureText(def)) continue;

    const value = config[key];

    if (typeof value === "string" && value.length > 0) {
      // Encrypt and upsert (delete + insert to work with partial unique indexes)
      const { ciphertext, iv } = await encrypt(value, encryptionKey);

      // Delete existing row first
      let deleteQuery = (db as any)
        .deleteFrom("secure_option")
        .where("twist_instance_id", "=", twistInstanceId)
        .where("key", "=", key);
      if (userId) {
        deleteQuery = deleteQuery.where("user_id", "=", userId);
      } else {
        deleteQuery = deleteQuery.where("user_id", "is", null);
      }
      await deleteQuery.execute();

      // Insert new row
      await db
        .insertInto("secure_option" as any)
        .values({
          twist_instance_id: twistInstanceId,
          key,
          encrypted_value: ciphertext,
          iv,
          ...(userId ? { user_id: userId } : {}),
        })
        .execute();

      // Replace plaintext with sentinel in config
      cleaned[key] = true;
    } else if (value === null) {
      // Delete the stored secret
      let query = (db as any)
        .deleteFrom("secure_option")
        .where("twist_instance_id", "=", twistInstanceId)
        .where("key", "=", key);
      if (userId) {
        query = query.where("user_id", "=", userId);
      } else {
        query = query.where("user_id", "is", null);
      }
      await query.execute();
      // Keep null in config (clears the value)
    } else if (value === true) {
      // Sentinel from client — unchanged, remove from config update
      delete cleaned[key];
    }
  }

  return cleaned;
}

/**
 * Resolve secure options at runtime by decrypting stored values.
 * Merges decrypted secure values into the resolved options object.
 *
 * @param userId - When provided, resolves per-user values first, falling back to shared.
 *                 When null/undefined, resolves shared values only.
 */
export async function resolveSecureOptions(
  db: Kysely<DB>,
  encryptionKey: string,
  twistInstanceId: string,
  schema: OptionsSchema,
  resolved: Record<string, unknown>,
  userId?: string | null
): Promise<Record<string, unknown>> {
  // Find which keys are secure
  const secureKeys = Object.entries(schema)
    .filter(([, def]) => def.type === "text" && "secure" in def && (def as any).secure)
    .map(([key]) => key);

  if (secureKeys.length === 0) return resolved;

  // Query shared secure_option rows (user_id IS NULL)
  const sharedRows = await (db as any)
    .selectFrom("secure_option")
    .select(["key", "encrypted_value", "iv"])
    .where("twist_instance_id", "=", twistInstanceId)
    .where("user_id", "is", null)
    .execute() as Array<{ key: string; encrypted_value: string; iv: string }>;

  // Decrypt shared values
  const merged = { ...resolved };
  for (const row of sharedRows) {
    if (secureKeys.includes(row.key)) {
      merged[row.key] = await decrypt(row.encrypted_value, row.iv, encryptionKey);
    }
  }

  // If userId provided, overlay per-user values (takes precedence over shared)
  if (userId) {
    const userRows = await (db as any)
      .selectFrom("secure_option")
      .select(["key", "encrypted_value", "iv"])
      .where("twist_instance_id", "=", twistInstanceId)
      .where("user_id", "=", userId)
      .execute() as Array<{ key: string; encrypted_value: string; iv: string }>;

    for (const row of userRows) {
      if (secureKeys.includes(row.key)) {
        merged[row.key] = await decrypt(row.encrypted_value, row.iv, encryptionKey);
      }
    }
  }

  return merged;
}

/**
 * Mask secure option values for client responses.
 * Replaces secure values with a sentinel object so clients know a value is set.
 */
export function maskSecureOptions(
  schema: OptionsSchema,
  config: Record<string, unknown>
): Record<string, unknown> {
  const masked = { ...config };

  for (const [key, def] of Object.entries(schema)) {
    if (def.type !== "text" || !("secure" in def) || !(def as any).secure) continue;
    // If a value is set (true sentinel or any truthy value), mask it
    if (masked[key]) {
      masked[key] = true;
    }
  }

  return masked;
}
