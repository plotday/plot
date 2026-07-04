import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import type { Bindings } from "../env";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import {
  isTokenKey,
  openTokenValue,
  sealTokenValue,
} from "../utils/token-encryption";

export class Storage extends DurableObject<Bindings> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private initializeTable() {
    const logger = createLogger({
      durable_object: "Storage",
      operation: "initializeTable",
    });

    try {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS store (
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (key)
        )
      `);
    } catch (error) {
      logger.error("Store table initialization error", error as Error);
      throw error;
    }
  }

  async get(key: string): Promise<string | null> {
    const logger = createLogger({
      durable_object: "Storage",
      operation: "get",
    });

    try {
      const result = this.sql
        .exec("SELECT value FROM store WHERE key = ?", [key])
        .next();
      if (result.done) {
        return null;
      }
      const raw = result.value.value as string;
      if (!isTokenKey(key)) {
        return raw;
      }
      const opened = await openTokenValue(raw, this.env.TOKEN_ENCRYPTION_KEY);
      if (opened === null) {
        // Unrecoverable (missing/rotated key or corrupt envelope). Treat as
        // absent so the caller prompts re-auth instead of parsing garbage.
        const error = new Error("Token decryption failed");
        logger.error("Failed to open encrypted token value", error, { key });
        const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
          host: this.env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
          before_send: exceptionFingerprintBeforeSend,
        });
        postHog.captureException(error, undefined, {
          durable_object: "Storage",
          operation: "get",
        });
        this.ctx.waitUntil(postHog.shutdown());
      }
      return opened;
    } catch (error) {
      logger.error("Store get error", error as Error, { key });
      throw error;
    }
  }

  async set(key: string, value: string): Promise<void> {
    const stored = isTokenKey(key)
      ? await sealTokenValue(value, this.env.TOKEN_ENCRYPTION_KEY)
      : value;
    this.sql.exec(
      `
          INSERT INTO store (key, value)
          VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET
            value = excluded.value
        `,
      key,
      stored
    );
  }

  /**
   * Bulk upsert in a single DO invocation. One RPC round-trip instead of one
   * per key — callers writing per-item caches (e.g. hundreds of message-id
   * mappings per sync pass) must use this instead of looping set().
   * Atomic: either every entry lands or none do.
   */
  async setMany(entries: [key: string, value: string][]): Promise<void> {
    if (entries.length === 0) return;
    // Seal token values outside the transaction (sealing is async;
    // transactionSync only wraps synchronous work).
    const sealed: [string, string][] = await Promise.all(
      entries.map(async ([key, value]): Promise<[string, string]> => [
        key,
        isTokenKey(key)
          ? await sealTokenValue(value, this.env.TOKEN_ENCRYPTION_KEY)
          : value,
      ])
    );
    this.ctx.storage.transactionSync(() => {
      for (const [key, stored] of sealed) {
        this.sql.exec(
          `
            INSERT INTO store (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET
              value = excluded.value
          `,
          key,
          stored
        );
      }
    });
  }

  list(prefix: string): string[] {
    // Cloudflare DO SQLite caps LIKE patterns at 50 bytes
    // (SQLITE_LIMIT_LIKE_PATTERN_LENGTH=50 in workerd), so a LIKE-based
    // prefix match throws "LIKE or GLOB pattern too complex" once the
    // prefix exceeds ~40 chars (e.g. `pending_occ:google-calendar:<iCalUID>:`).
    // Range scan instead, and the prefix is matched literally — `%` / `_`
    // in the caller's prefix are not interpreted as wildcards.
    if (prefix.length === 0) {
      const all = this.sql.exec(
        "SELECT key FROM store WHERE key NOT LIKE '__lock__:%'"
      );
      return [...all].map((r) => r.key as string);
    }
    const lastChar = prefix.charCodeAt(prefix.length - 1);
    const upperBound =
      prefix.slice(0, -1) + String.fromCharCode(lastChar + 1);
    const ranged = this.sql.exec(
      "SELECT key FROM store WHERE key >= ? AND key < ? AND key NOT LIKE '__lock__:%'",
      prefix,
      upperBound
    );
    return [...ranged].map((r) => r.key as string);
  }

  clear(key: string) {
    this.sql.exec("DELETE FROM store WHERE key = ?", key);
  }

  clearAll() {
    this.sql.exec("DELETE FROM store");
  }

  /**
   * Atomic check-and-set lock acquisition. DO method invocations are
   * serialized, so the read-then-write here is race-free.
   *
   * Returns true if the lock was acquired (caller must call releaseLock or
   * wait for expiry). Returns false if a non-expired lock already exists.
   * Locks live under a reserved `__lock__:` prefix so list("") / get() never
   * surface them.
   *
   * @param key User-visible lock key (transparently namespaced internally).
   * @param ttlMs Lease duration. Lock auto-expires after this many ms even
   *   if releaseLock is never called — protects against orphaned locks
   *   when a sync crashes.
   */
  acquireLock(key: string, ttlMs: number): boolean {
    const lockKey = `__lock__:${key}`;
    const now = Date.now();
    const existing = this.sql
      .exec("SELECT value FROM store WHERE key = ?", [lockKey])
      .next();
    if (!existing.done) {
      const expiresAt = parseInt(existing.value.value as string, 10);
      if (Number.isFinite(expiresAt) && expiresAt > now) {
        return false;
      }
    }
    this.sql.exec(
      `INSERT INTO store (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      lockKey,
      String(now + ttlMs)
    );
    return true;
  }

  releaseLock(key: string): void {
    this.sql.exec("DELETE FROM store WHERE key = ?", `__lock__:${key}`);
  }
}
