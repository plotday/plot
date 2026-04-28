import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";

export class Storage extends DurableObject {
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

  get(key: string): string | null {
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
      return result.value.value as string;
    } catch (error) {
      logger.error("Store get error", error as Error, { key });
      throw error;
    }
  }

  set(key: string, value: string): void {
    this.sql.exec(
      `
          INSERT INTO store (key, value) 
          VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET 
            value = excluded.value
        `,
      key,
      value
    );
  }

  list(prefix: string): string[] {
    const results = this.sql.exec(
      "SELECT key FROM store WHERE key LIKE ? AND key NOT LIKE '__lock__:%'",
      `${prefix}%`
    );
    return [...results].map((r) => r.key as string);
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
