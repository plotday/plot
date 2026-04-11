import { DurableObject } from "cloudflare:workers";
import superjson from "superjson";

import { createLogger } from "@plotday/worker-util";

import { createDb, sql, type DB, type Kysely } from "../db";
import { type Bindings } from "../env";
import { CallbackError } from "../errors";
import { Usage } from "../state/usage";
import { twistFactory } from "../twist";
import { handleTwistOperation } from "../twist/error-handling";
import { validateSerializable } from "../twist/tools/validation";
import { disposeRpc } from "../utils/rpc";

export type CallbackData = {
  token: string;
  priorityTwistId: string;
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
  priorityTwistId: string;
  path: string[];
  functionName: string;
  extraArgs?: any[];
  callOnce: boolean;
};

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
          priority_twist_id TEXT NOT NULL,
          path TEXT NOT NULL,
          version TEXT NOT NULL,
          function_name TEXT NOT NULL,
          extra_args TEXT,
          call_at INTEGER,
          call_once INTEGER DEFAULT 0,
          expires INTEGER
        )
      `);
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_priority_twist
        ON callbacks(priority_twist_id)
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
    priorityTwistId,
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
    priorityTwistId: string;
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
          .selectFrom("priority_twist")
          .select("twist_id")
          .where("id", "=", priorityTwistId)
          .executeTakeFirst();

        if (!ptData) {
          throw new Error(
            `Failed to fetch priority_twist ${priorityTwistId}: No data found`
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
          token, priority_twist_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      priorityTwistId,
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
          SELECT token, priority_twist_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
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
      priorityTwistId: rawCallback.priority_twist_id,
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
      const priorityTwist = await db
        .selectFrom("priority_twist")
        .innerJoin("twist", "twist.id", "priority_twist.twist_id")
        .select([
          "priority_twist.priority_id",
          "priority_twist.twist_id",
          "priority_twist.archived_at",
          "priority_twist.suspended_at",
          "twist.execution_limit",
        ])
        .where("priority_twist.id", "=", callback.priorityTwistId)
        .executeTakeFirst();

      // If priority_twist was deleted, clean up callback and return error object
      if (!priorityTwist) {
        this.delete(token);
        // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
        return {
          __error: true,
          type: "NOT_FOUND",
          context: {
            operation: "callCallback",
            priorityTwistId: callback.priorityTwistId,
            reason: "Priority twist deleted",
          },
        };
      }

      // If priority_twist is archived, clean up callback and return error object
      // This is expected behavior when a twist is uninstalled
      if (priorityTwist.archived_at) {
        this.delete(token);
        // Return error object instead of throwing to prevent DO runtime from logging as "Uncaught"
        return {
          __error: true,
          type: "NOT_FOUND",
          context: {
            operation: "callCallback",
            priorityTwistId: callback.priorityTwistId,
            reason: "Priority twist archived",
          },
        };
      }

      // If priority_twist is suspended, block without deleting callback (allows retry after resume)
      if (priorityTwist.suspended_at) {
        return {
          __error: true,
          type: "SUSPENDED",
          context: {
            operation: "callCallback",
            priorityTwistId: callback.priorityTwistId,
            reason: "Twist processing suspended due to high usage",
          },
        };
      }

      // Check execution quota
      const usage = Usage.Get(this.env, callback.priorityTwistId);
      const withinQuota = await usage.checkExecutionQuota(
        priorityTwist.execution_limit
      );
      if (!withinQuota) {
        return {
          __error: true,
          type: "SUSPENDED",
          context: {
            operation: "callCallback",
            priorityTwistId: callback.priorityTwistId,
            reason:
              "Twist processing suspended due to execution quota exceeded",
          },
        };
      }

      // Fetch twist metadata including environment and twist_package_id (for log routing)
      const twistMeta = await db
        .selectFrom("twist")
        .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
        .select(["twist.environment", "twist_admin.twist_package_id"])
        .where("twist.id", "=", priorityTwist.twist_id)
        .executeTakeFirst();

      // If twist was deleted, clean up callback and return
      if (!twistMeta) {
        logger.warn("Twist not found for callback, deleting callback", {
          twistId: priorityTwist.twist_id,
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
        priorityId: priorityTwist.priority_id!,
        priorityTwistId: callback.priorityTwistId,
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
          priority_twist_id: callback.priorityTwistId,
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
          SELECT token, priority_twist_id, path, function_name, extra_args, call_once, expires
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
      priorityTwistId: row.priority_twist_id,
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

  delete(token: string): void {
    [, token] = token.split(":");
    this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
  }

  deleteAll(
    args:
      | {
          priorityTwistId: string;
          path?: string[];
          reallyDeleteEverything?: boolean;
        }
      | { reallyDeleteEverything: true }
  ): void {
    if (args.reallyDeleteEverything) {
      this.sql.exec("DELETE FROM callbacks");
      return;
    }
    const { priorityTwistId, path } = args;
    this.sql.exec(
      "DELETE FROM callbacks WHERE priority_twist_id = ?" +
        (path ? " AND path = ?" : ""),
      ...(path
        ? [priorityTwistId, superjson.stringify(path)]
        : [priorityTwistId])
    );
  }

  /**
   * Upgrade all callbacks for a priority_twist to a new version.
   * This is called during twist deployment to ensure webhooks execute with the new version.
   */
  upgradeCallbacks(priorityTwistId: string, newVersion: string): void {
    // Update version for all callbacks belonging to this priority_twist
    this.sql.exec(
      "UPDATE callbacks SET version = ? WHERE priority_twist_id = ?",
      newVersion,
      priorityTwistId
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

    // Find all callbacks that should be executed now
    const now = Date.now();
    const callbackResults = this.sql.exec(
      `
        SELECT token, extra_args
        FROM callbacks
        WHERE call_at IS NOT NULL
          AND call_at <= ?
        ORDER BY call_at ASC
      `,
      [now]
    );

    for (const row of callbackResults) {
      const token = row.token as string;
      try {
        await this.callCallback(`${this.ctx.id}:${token}`);
      } catch (error) {
        logger.error("Callback failed", error as Error, { token });
      } finally {
        this.sql.exec(
          "UPDATE callbacks SET call_at = NULL WHERE token = ?",
          token
        );
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

  /**
   * Static method to call a callback by token.
   * Parses the token to extract priorityTwistId, gets the correct DO stub,
   * and executes the callback.
   */
  static async CallCallback(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    ...args: any[]
  ): Promise<any> {
    if (!token || token.trim() === "") {
      throw new CallbackError("INVALID_TOKEN", {
        operation: "CallCallback",
      });
    }

    const [id] = token.split(":");

    // Validate DO ID format before attempting to create stub
    if (!isValidDoId(id)) {
      throw new CallbackError("INVALID_TOKEN_FORMAT", {
        operation: "CallCallback",
        token: token.substring(0, 8) + "...",
      });
    }

    const callbacksId = callbacks.idFromString(id);
    const callbacksStub = callbacks.get(callbacksId);

    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    const result = await callbacksStub.callCallback(token, ...args);
    disposeRpc(callbacksStub);

    // Check if the result is an error object (returned instead of thrown to prevent "Uncaught" logs)
    if (
      result &&
      typeof result === "object" &&
      "__error" in result &&
      result.__error === true
    ) {
      // Convert error object back to CallbackError and throw
      throw new CallbackError(result.type as any, result.context);
    }

    return result;
  }
}
