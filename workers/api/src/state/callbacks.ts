import { DurableObject } from "cloudflare:workers";
import superjson from "superjson";

import { createLogger } from "@plotday/worker-util";

import { createDb, sql, type DB, type Kysely } from "../db";
import { type Bindings } from "../env";
import { CallbackError, type CallbackErrorContext } from "../errors";
import { Usage } from "../state/usage";
import { twistFactory } from "../twist";
import { handleTwistOperation } from "../twist/error-handling";
import { validateSerializable } from "../twist/tools/validation";

export type CallbackData = {
  token: string;
  twistInstanceId: string;
  path: string[]; // tool hierarchy only
  version: string; // twist version
  functionName: string;
  extraArgs?: any[];
  callAt?: Date;
  callOnce?: boolean;
  expires?: Date;
  key?: string;
  meta?: Record<string, any>;
};

/**
 * Subset of CallbackData returned by resolve() for local execution.
 * Contains only what's needed to invoke the callback directly on an
 * already-constructed tool tree, avoiding full twist reconstruction.
 */
export type ResolvedCallback = {
  twistInstanceId: string;
  path: string[];
  functionName: string;
  extraArgs?: any[];
  callOnce: boolean;
};

/**
 * Result of validateAndLoad(): the SQLite-resolved callback row. The
 * caller (invokeWebhookCallback) does the twist_instance / quota lookup
 * and the twist worker RPC outside this DO so the output gate is only
 * held for the cheap SQLite read here. Cloudflare resets the DO if the
 * gate is held past the storage watchdog (observed in production when
 * Hyperdrive was contended).
 */
export type LoadedCallback = {
  ok: true;
  callback: CallbackData;
};

export type LoadError = {
  __error: true;
  type: "NOT_FOUND" | "EXPIRED" | "SUSPENDED" | "INVALID_TOKEN";
  context?: CallbackErrorContext;
};

export type LoadResult = LoadedCallback | LoadError;

/**
 * Validates if a string is a valid Durable Object ID (64 hex characters)
 */
function isValidDoId(id: string): boolean {
  return /^[0-9a-f]{64}$/i.test(id);
}

function isTransientDbError(error: unknown): boolean {
  const msg = (error as Error)?.message ?? "";
  return msg.includes("shutting down") || msg.includes("connection terminated");
}

export class CallbacksState extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private db?: Kysely<DB>;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
  }

  /**
   * Run `fn` with a long-lived Kysely instance held on this DO.
   *
   * Durable Objects are stateful and single-threaded: holding a DB connection
   * across calls avoids the per-request pool churn that would otherwise
   * exhaust Postgres (and kill local dev) when a connector fires a burst of
   * webhooks into the same DO instance.
   *
   * On a transient connection error ("shutting down" / "connection
   * terminated"), destroy the cached instance and retry once with a fresh
   * one. Mirrors the retry semantics of the module-level withDb helper.
   */
  private async withDb<T>(fn: (db: Kysely<DB>) => Promise<T>): Promise<T> {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (!this.db) {
        this.db = createDb(this.env);
        // Set statement_timeout explicitly as a fallback for when the
        // underlying pg connection was reused by Hyperdrive past its startup
        // phase — matches the module-level withDb behavior.
        await sql`SET statement_timeout = 30000`.execute(this.db);
      }
      try {
        return await fn(this.db);
      } catch (error) {
        if (attempt === 0 && isTransientDbError(error)) {
          const stale = this.db;
          this.db = undefined;
          void stale?.destroy();
          continue;
        }
        throw error;
      }
    }
    // Unreachable — the loop either returns or throws.
    throw new Error("withDb retry loop exited without result");
  }

  /**
   * Parse with superjson, falling back to JSON.parse for backward compatibility
   */
  private parseWithFallback<T>(value: string): T {
    try {
      return superjson.parse<T>(value);
    } catch {
      try {
        return JSON.parse(value) as T;
      } catch {
        throw new Error(`Failed to parse value: ${value}`);
      }
    }
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private initializeTable() {
    this.sql.exec(`
        CREATE TABLE IF NOT EXISTS callbacks (
          token TEXT PRIMARY KEY,
          twist_instance_id TEXT NOT NULL,
          path TEXT NOT NULL,
          version TEXT NOT NULL,
          function_name TEXT NOT NULL,
          extra_args TEXT,
          call_at INTEGER,
          call_once INTEGER DEFAULT 0,
          expires INTEGER
        )
      `);
    // Migrate pre-rename storage: priority_twist_id → twist_instance_id.
    // DO SQLite state persists locally; older installs still have the old column.
    try {
      this.sql.exec(
        "ALTER TABLE callbacks RENAME COLUMN priority_twist_id TO twist_instance_id",
      );
    } catch (e) {
      // Already renamed (or table freshly created with new name).
    }
    try {
      this.sql.exec("DROP INDEX IF EXISTS idx_callbacks_priority_twist");
    } catch (e) {
      // Old index didn't exist.
    }
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_twist_instance
        ON callbacks(twist_instance_id)
      `);
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_call_at
        ON callbacks(call_at) WHERE call_at IS NOT NULL
      `);

    // Add key and meta columns for provider-specific routing (migration-safe)
    try {
      this.sql.exec("ALTER TABLE callbacks ADD COLUMN key TEXT");
    } catch (e) {
      // Column already exists
    }
    try {
      this.sql.exec("ALTER TABLE callbacks ADD COLUMN meta TEXT");
    } catch (e) {
      // Column already exists
    }
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_key
        ON callbacks(key) WHERE key IS NOT NULL
      `);
  }

  async create({
    twistInstanceId,
    path,
    version,
    functionName,
    extraArgs,
    callAt,
    callOnce,
    expires,
    key,
    meta,
  }: {
    twistInstanceId: string;
    path: string[]; // tool hierarchy only
    version?: string;
    functionName: string;
    extraArgs?: Exclude<any, Function>[];
    callAt?: Date;
    callOnce?: boolean;
    expires?: Date;
    key?: string;
    meta?: Record<string, any>;
  }): Promise<string> {
    // Validate extra args if provided
    // Note: SuperJSON handles undefined values, so no need to clean them
    if (extraArgs !== undefined && extraArgs.length > 0) {
      validateSerializable(
        `create callback args for function "${functionName}"`,
        extraArgs
      );
    }

    // Fetch twist_id, environment, and version from database if version not provided
    if (!version) {
      version = await this.withDb(async (db) => {
        const ptData = await db
          .selectFrom("twist_instance")
          .select("twist_id")
          .where("id", "=", twistInstanceId)
          .executeTakeFirst();

        if (!ptData) {
          throw new Error(
            `Failed to fetch twist_instance ${twistInstanceId}: No data found`
          );
        }

        const data = await db
          .selectFrom("twist")
          .select(["version", "environment"])
          .where("id", "=", ptData.twist_id)
          .executeTakeFirst();

        if (!data?.version) {
          throw new Error(
            `Failed to fetch version for twist_id ${ptData.twist_id}: No version found`
          );
        }
        return data.version;
      });
    }

    const token = this.generateToken();

    // Default callOnce to true if callAt is specified, false otherwise
    callOnce ??= callAt !== undefined;

    this.sql.exec(
      `
        INSERT INTO callbacks (
          token, twist_instance_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      twistInstanceId,
      superjson.stringify(path),
      version,
      functionName,
      extraArgs ? superjson.stringify(extraArgs) : null,
      callAt ? callAt.getTime() : null,
      callOnce ? 1 : 0,
      expires ? expires.getTime() : null,
      key ?? null,
      meta ? superjson.stringify(meta) : null
    );

    // Update alarm if this is a scheduled callback
    if (callAt) {
      this.updateAlarm();
    }

    // Encode id in token for routing
    // Safety check: validate that the DO ID is in the correct format
    const doId = String(this.ctx.id);
    if (!isValidDoId(doId)) {
      throw new Error(`Generated invalid DO ID: ${doId}`);
    }

    return `${doId}:${token}`;
  }

  /**
   * Resolve a callback token from local SQLite. Cheap, no Hyperdrive,
   * no cross-DO RPC. The caller (typically `invokeWebhookCallback`)
   * handles the twist_instance / quota / archive checks and the twist
   * worker RPC outside this DO, because doing them here held the output
   * gate long enough that Cloudflare reset the DO under load.
   *
   * Side effects: deletes the callback row for `EXPIRED`. Cleanup for
   * "twist deleted/archived" happens in the worker via `delete()` after
   * the worker-side DB lookup returns.
   *
   * Takes the full `doId:token` format (the same thing `callCallback`
   * accepts).
   */
  validateAndLoad(fullToken: string): LoadResult {
    if (!fullToken) {
      return {
        __error: true,
        type: "INVALID_TOKEN",
        context: { operation: "validateAndLoad" },
      };
    }
    const [, token] = fullToken.split(":");
    if (!token) {
      return {
        __error: true,
        type: "INVALID_TOKEN",
        context: {
          operation: "validateAndLoad",
          reason: "Missing colon separator",
        },
      };
    }

    const result = this.sql
      .exec(
        `
          SELECT token, twist_instance_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
          FROM callbacks
          WHERE token = ?
          `,
        [token]
      )
      .next();
    if (result.done) {
      return {
        __error: true,
        type: "NOT_FOUND",
        context: {
          operation: "validateAndLoad",
          token: token.substring(0, 8) + "...",
        },
      };
    }
    const rawCallback = result.value as any;
    const callback: CallbackData = {
      token: rawCallback.token,
      twistInstanceId: rawCallback.twist_instance_id,
      path: this.parseWithFallback(rawCallback.path),
      version: rawCallback.version,
      functionName: rawCallback.function_name,
      extraArgs: rawCallback.extra_args
        ? this.parseWithFallback(rawCallback.extra_args)
        : undefined,
      callAt: rawCallback.call_at ? new Date(rawCallback.call_at) : undefined,
      callOnce: Boolean(rawCallback.call_once),
      expires: rawCallback.expires ? new Date(rawCallback.expires) : undefined,
      key: rawCallback.key ?? undefined,
      meta: rawCallback.meta
        ? this.parseWithFallback(rawCallback.meta)
        : undefined,
    };

    if (callback.expires && callback.expires < new Date()) {
      this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
      return {
        __error: true,
        type: "EXPIRED",
        context: {
          operation: "validateAndLoad",
          token: token.substring(0, 8) + "...",
        },
      };
    }

    return { ok: true, callback };
  }

  async callCallback(
    token: string,
    ...args: any[]
  ): Promise<any | { __error: true; type: string; context?: any }> {
    const logger = createLogger({
      durable_object: "CallbacksState",
      operation: "callCallback",
    });

    if (!token) {
      throw new CallbackError("INVALID_TOKEN", {
        operation: "callCallback",
      });
    }
    [, token] = token.split(":");
    if (!token) {
      throw new CallbackError("INVALID_TOKEN", {
        operation: "callCallback",
        reason: "Missing colon separator",
      });
    }
    const result = this.sql
      .exec(
        `
          SELECT token, twist_instance_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
          FROM callbacks
          WHERE token = ?
          `,
        [token]
      )
      .next();
    if (result.done) {
      // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
      return {
        __error: true,
        type: "NOT_FOUND",
        context: {
          operation: "callCallback",
          token: token.substring(0, 8) + "...",
        },
      };
    }
    const rawCallback = result.value as any;
    const callback: CallbackData = {
      token: rawCallback.token,
      twistInstanceId: rawCallback.twist_instance_id,
      path: this.parseWithFallback(rawCallback.path),
      version: rawCallback.version,
      functionName: rawCallback.function_name,
      extraArgs: rawCallback.extra_args
        ? this.parseWithFallback(rawCallback.extra_args)
        : undefined,
      callAt: rawCallback.call_at ? new Date(rawCallback.call_at) : undefined,
      callOnce: Boolean(rawCallback.call_once),
      expires: rawCallback.expires ? new Date(rawCallback.expires) : undefined,
      key: rawCallback.key ?? undefined,
      meta: rawCallback.meta
        ? this.parseWithFallback(rawCallback.meta)
        : undefined,
    };

    // Check if callback has expired
    if (callback.expires && callback.expires < new Date()) {
      this.delete(token);
      // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
      return {
        __error: true,
        type: "EXPIRED",
        context: {
          operation: "callCallback",
          token: token.substring(0, 8) + "...",
        },
      };
    }

    const { path } = callback;
    const timingEnabled = this.env.SYNC_TIMING_ENABLED === "true";
    let dbLookupStart: number | undefined;
    if (timingEnabled) {
      dbLookupStart = Date.now();
    }

    return await this.withDb(async (db) => {
      const twistInstance = await db
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select([
          "twist_instance.twist_id",
          "twist_instance.archived_at",
          "twist_instance.suspended_at",
          "twist.execution_limit",
        ])
        .where("twist_instance.id", "=", callback.twistInstanceId)
        .executeTakeFirst();

      // If twist_instance was deleted, clean up callback and return error object
      if (!twistInstance) {
        this.delete(token);
        // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
        return {
          __error: true,
          type: "NOT_FOUND",
          context: {
            operation: "callCallback",
            twistInstanceId: callback.twistInstanceId,
            reason: "Priority twist deleted",
          },
        };
      }

      // If twist_instance is archived, clean up callback and return error object
      // This is expected behavior when a twist is uninstalled
      if (twistInstance.archived_at) {
        this.delete(token);
        // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
        return {
          __error: true,
          type: "NOT_FOUND",
          context: {
            operation: "callCallback",
            twistInstanceId: callback.twistInstanceId,
            reason: "Priority twist archived",
          },
        };
      }

      // If twist_instance is suspended, block without deleting callback (allows retry after resume)
      if (twistInstance.suspended_at) {
        return {
          __error: true,
          type: "SUSPENDED",
          context: {
            operation: "callCallback",
            twistInstanceId: callback.twistInstanceId,
            reason: "Twist processing suspended due to high usage",
          },
        };
      }

      // Check execution quota
      const usage = Usage.Get(this.env, callback.twistInstanceId);
      const withinQuota = await usage.checkExecutionQuota(
        twistInstance.execution_limit
      );
      if (!withinQuota) {
        return {
          __error: true,
          type: "SUSPENDED",
          context: {
            operation: "callCallback",
            twistInstanceId: callback.twistInstanceId,
            reason:
              "Twist processing suspended due to execution quota exceeded",
          },
        };
      }

      // Fetch twist metadata including environment and twist_package_id (for log routing)
      const twistMeta = await db
        .selectFrom("twist")
        .select(["twist.environment", "twist.twist_package_id"])
        .where("twist.id", "=", twistInstance.twist_id)
        .executeTakeFirst();

      // If twist was deleted, clean up callback and return
      if (!twistMeta) {
        logger.warn("Twist not found for callback, deleting callback", {
          twistId: twistInstance.twist_id,
          token,
        });
        this.delete(token);
        return;
      }

      let dbLookupMs: number | undefined;
      let factoryInitStart: number | undefined;
      if (timingEnabled) {
        dbLookupMs = Date.now() - dbLookupStart!;
        factoryInitStart = Date.now();
      }

      const factory = twistFactory({
        env: this.env,
        ctx: this.ctx,
        db,
      });
      const twistWrapper = await factory({
        version: callback.version,
        twistInstanceId: callback.twistInstanceId,
      });

      let factoryInitMs: number | undefined;
      let callbackExecStart: number | undefined;
      if (timingEnabled) {
        factoryInitMs = Date.now() - factoryInitStart!;
        callbackExecStart = Date.now();
      }

      // Call the callback with error handling (works for both twists and tools via path parameter)
      let callResult: any;
      try {
        callResult = await handleTwistOperation(
          `callback: ${callback.functionName}`,
          async () => {
            return await twistWrapper.callCallback(
              path,
              callback.functionName,
              ...(args ?? []),
              ...(callback.extraArgs ?? [])
            );
          },
          {
            env: this.env,
            id: twistMeta.twist_package_id,
            version: callback.version,
            environment: twistMeta.environment,
          }
        );
      } catch (error) {
        // If the tool path no longer exists, delete the callback to prevent repeated failures
        if (
          error instanceof Error &&
          error.message.includes("Tool not found at path")
        ) {
          logger.warn("Deleting callback for removed tool", {
            token: token.substring(0, 8) + "...",
            path: path.join(" > "),
            function_name: callback.functionName,
          });
          this.delete(`_:${token}`);
        }
        throw error;
      }

      if (timingEnabled) {
        const callbackExecMs = Date.now() - callbackExecStart!;
        logger.info("Callback execution timing", {
          token: token.substring(0, 8) + "...",
          function_name: callback.functionName,
          twist_instance_id: callback.twistInstanceId,
          db_lookup_ms: dbLookupMs,
          factory_init_ms: factoryInitMs,
          callback_exec_ms: callbackExecMs,
          total_ms: (dbLookupMs ?? 0) + (factoryInitMs ?? 0) + callbackExecMs,
        });
      }

      if (callback.callOnce) {
        this.delete(token);
      }

      return callResult;
    });
  }

  /**
   * Resolves callback metadata without executing it.
   *
   * Used by the twist worker to execute callbacks locally on its
   * already-constructed tool tree, avoiding the expensive path of
   * constructing a new twist via twistFactory (which involves
   * Supabase queries, module loading, permission checks, and a
   * full tool tree rebuild).
   *
   * Only performs a local SQLite lookup — no Supabase queries.
   * Does NOT handle callOnce deletion; the caller is responsible
   * for calling delete() after successful execution.
   */
  resolve(token: string): ResolvedCallback | null {
    if (!token) return null;
    [, token] = token.split(":");
    if (!token) return null;

    const result = this.sql
      .exec(
        `
          SELECT token, twist_instance_id, path, function_name, extra_args, call_once, expires
          FROM callbacks
          WHERE token = ?
          `,
        [token]
      )
      .next();
    if (result.done) return null;

    const row = result.value as any;

    // Check expiration
    if (row.expires && row.expires < Date.now()) {
      this.delete(`_:${token}`);
      return null;
    }

    return {
      twistInstanceId: row.twist_instance_id,
      path: this.parseWithFallback(row.path),
      functionName: row.function_name,
      extraArgs: row.extra_args
        ? this.parseWithFallback(row.extra_args)
        : undefined,
      callOnce: Boolean(row.call_once),
    };
  }

  get(key: string): Array<{ callback: string; meta?: Record<string, any> }> {
    const results = this.sql.exec(
      `
        SELECT token, meta
        FROM callbacks
        WHERE key = ?
        `,
      [key]
    );

    const callbacks: Array<{ callback: string; meta?: Record<string, any> }> =
      [];
    for (const row of results) {
      callbacks.push({
        callback: `${this.ctx.id}:${row.token}`,
        meta: row.meta ? this.parseWithFallback(row.meta as string) : undefined,
      });
    }
    return callbacks;
  }

  /**
   * True if this twist_instance has at least one *scheduled* callback whose
   * `call_at` is still in the future — i.e. a pending `Tasks.runTask({ runAt })`
   * batch that the alarm will fire to resume work. The stuck-sync watchdog
   * (workers/api/src/scheduled/recover-stuck-syncs.ts) uses this to tell a
   * healthy long-running / rate-limited sync (has a future batch queued)
   * apart from one orphaned by a worker crash (nothing left to fire).
   *
   * Only future scheduled rows count as "alive": an immediate (`call_at IS
   * NULL`) task row can linger after the run queue exhausts its retries, so
   * it is NOT a reliable liveness signal; a past-due scheduled row is
   * consumed-and-deleted by the alarm, so it never lingers either.
   */
  hasPendingScheduledCallback(twistInstanceId: string): boolean {
    const result = this.sql
      .exec(
        `
        SELECT 1
        FROM callbacks
        WHERE twist_instance_id = ?
          AND call_at IS NOT NULL
          AND call_at > ?
        LIMIT 1
        `,
        twistInstanceId,
        Date.now()
      )
      .next();
    return !result.done;
  }

  delete(token: string): void {
    [, token] = token.split(":");
    this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
  }

  deleteAll(
    args:
      | {
          twistInstanceId: string;
          path?: string[];
          reallyDeleteEverything?: boolean;
        }
      | { reallyDeleteEverything: true }
  ): void {
    if (args.reallyDeleteEverything) {
      this.sql.exec("DELETE FROM callbacks");
      return;
    }
    const { twistInstanceId, path } = args;
    this.sql.exec(
      "DELETE FROM callbacks WHERE twist_instance_id = ?" +
        (path ? " AND path = ?" : ""),
      ...(path
        ? [twistInstanceId, superjson.stringify(path)]
        : [twistInstanceId])
    );
  }

  /**
   * Upgrade all callbacks for a twist_instance to a new version.
   * This is called during twist deployment to ensure webhooks execute with the new version.
   */
  upgradeCallbacks(twistInstanceId: string, newVersion: string): void {
    // Update version for all callbacks belonging to this twist_instance
    this.sql.exec(
      "UPDATE callbacks SET version = ? WHERE twist_instance_id = ?",
      newVersion,
      twistInstanceId
    );
  }

  private updateAlarm(): void {
    // Find the next callback that needs to be executed
    const alarmResult = this.sql
      .exec(
        `
          SELECT call_at
          FROM callbacks 
          WHERE call_at IS NOT NULL 
            AND call_at > ?
          ORDER BY call_at ASC 
          LIMIT 1
        `,
        [Date.now()]
      )
      .next();

    if (alarmResult.done) {
      // No more scheduled callbacks, delete any existing alarm
      this.ctx.storage.deleteAlarm();
    } else {
      const nextCallAt = alarmResult.value.call_at as number;
      this.ctx.storage.setAlarm(nextCallAt);
    }
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "CallbacksState",
      operation: "alarm",
    });

    // Every Tasks.runTask({ runAt }) row stores function_name="scheduledSend"
    // and extra_args=[taskToken]. Re-enqueue them straight into RUN_QUEUE
    // here instead of routing through this.callCallback, which runs
    // withDb (Hyperdrive query) inside the DO and holds the output gate
    // long enough that Cloudflare resets the DO ("Internal error in
    // Durable Object storage caused object to be reset"). The companion
    // commit fb0004010 routed every worker-context caller off of this
    // DO for the same reason; the alarm self-dispatch was the last
    // hold-out and was firing this reset 139+ times across users today.
    const now = Date.now();
    const callbackResults = this.sql.exec(
      `
        SELECT token, twist_instance_id, path, function_name, extra_args, call_once
        FROM callbacks
        WHERE call_at IS NOT NULL
          AND call_at <= ?
        ORDER BY call_at ASC
      `,
      [now]
    );

    for (const row of callbackResults) {
      const token = row.token as string;
      const functionName = row.function_name as string;

      if (functionName === "scheduledSend") {
        try {
          const twistInstanceId = row.twist_instance_id as string;
          const path = this.parseWithFallback<string[]>(row.path as string);
          const extraArgsRaw = row.extra_args as string | null;
          const extraArgs = extraArgsRaw
            ? this.parseWithFallback<unknown[]>(extraArgsRaw)
            : [];
          const taskToken = extraArgs[0];
          if (typeof taskToken !== "string") {
            logger.warn(
              "scheduledSend row missing string taskToken in extra_args; skipping",
              { token: token.substring(0, 8) + "..." }
            );
          } else {
            // Stored path is the Tasks tool's selfPath; the queue
            // consumer's path field matches what Tasks.send writes
            // (selfPath.slice(0,-1)).
            const parentPath = path.slice(0, -1);
            await this.env.RUN_QUEUE.send({
              twistInstanceId,
              path: parentPath,
              token: taskToken,
              queuedAt: Date.now(),
            });
          }
        } catch (error) {
          logger.error("Failed to re-enqueue scheduled task", error as Error, {
            token: token.substring(0, 8) + "...",
          });
        } finally {
          // callOnce defaults to true for scheduled callbacks (see create()).
          if (Number(row.call_once) === 1) {
            this.sql.exec(
              "DELETE FROM callbacks WHERE token = ?",
              token
            );
          } else {
            this.sql.exec(
              "UPDATE callbacks SET call_at = NULL WHERE token = ?",
              token
            );
          }
        }
      } else {
        // Legacy / uncommon: a callAt row whose function isn't
        // scheduledSend. Keep the old this.callCallback path but warn so
        // we know if any non-Tasks scheduled callbacks exist in the wild.
        logger.warn(
          "Alarm firing non-scheduledSend callback via legacy path",
          {
            token: token.substring(0, 8) + "...",
            function_name: functionName,
          }
        );
        try {
          await this.callCallback(`${this.ctx.id}:${token}`);
        } catch (error) {
          logger.error("Callback failed", error as Error, {
            token: token.substring(0, 8) + "...",
          });
        } finally {
          this.sql.exec(
            "UPDATE callbacks SET call_at = NULL WHERE token = ?",
            token
          );
        }
      }
    }

    // Set the next alarm
    this.updateAlarm();
  }

  private generateToken(): string {
    // Generate 32 bytes of random data and encode as URL-safe base64
    const randomBytes = new Uint8Array(32);
    crypto.getRandomValues(randomBytes);

    // Convert to base64 and make URL-safe
    const base64 = btoa(
      Array.from(randomBytes, (byte) => String.fromCharCode(byte)).join("")
    );
    return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  }

}
