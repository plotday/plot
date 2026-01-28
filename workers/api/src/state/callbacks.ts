import { DurableObject } from "cloudflare:workers";
import superjson from "superjson";

import { type SupabaseClient, createClient, safeQuery } from "@plotday/db";

import { type Bindings } from "../env";
import { twistFactory } from "../twist";
import { handleTwistOperation } from "../twist/error-handling";
import { validateSerializable } from "../twist/tools/validation";
import { createLogger } from "../utils/logger";

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
 * Validates if a string is a valid Durable Object ID (64 hex characters)
 */
function isValidDoId(id: string): boolean {
  return /^[0-9a-f]{64}$/i.test(id);
}

export class CallbacksState extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private supabase: SupabaseClient;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
    this.supabase = createClient(
      this.env.SUPABASE_URL,
      this.env.SUPABASE_SERVICE_KEY
    );
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
      const { data: ptData, error: ptError } = await this.supabase
        .from("priority_twist")
        .select("twist_id")
        .eq("id", priorityTwistId)
        .single();

      if (ptError || !ptData) {
        throw new Error(
          `Failed to fetch priority_twist ${priorityTwistId}: ${
            ptError?.message || "No data found"
          }`
        );
      }

      const { data, error } = await this.supabase
        .from("twist")
        .select("version,environment")
        .eq("id", ptData.twist_id)
        .single();

      if (error || !data?.version) {
        throw new Error(
          `Failed to fetch version for twist_id ${ptData.twist_id}: ${
            error?.message || "No version found"
          }`
        );
      }
      version = data.version;
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

  async callCallback(token: string, ...args: any[]): Promise<any> {
    const logger = createLogger({
      durable_object: "CallbacksState",
      operation: "callCallback",
    });

    if (!token) {
      throw new Error("Invalid callback token");
    }
    [, token] = token.split(":");
    if (!token) {
      throw new Error("Invalid callback token");
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
      logger.warn("Callback not found for token", { token });
      throw new Error("Callback not found");
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
      meta: rawCallback.meta ? this.parseWithFallback(rawCallback.meta) : undefined,
    };

    // Check if callback has expired
    if (callback.expires && callback.expires < new Date()) {
      this.delete(token);
      throw new Error("Callback has expired");
    }

    const { path } = callback;

    const priorityTwist = safeQuery(
      await this.supabase
        .from("priority_twist")
        .select("priority_id, twist_id")
        .eq("id", callback.priorityTwistId)
        .maybeSingle(),
      {
        table: "priority_twist",
        operation: "SELECT",
        description: "Fetch priority and twist_id for callback execution",
        identifiers: { priorityTwistId: callback.priorityTwistId },
      }
    );

    // If priority_twist was deleted, clean up callback and return
    if (!priorityTwist) {
      logger.warn("Priority twist not found for callback, deleting callback", {
        priorityTwistId: callback.priorityTwistId,
        token,
      });
      this.delete(token);
      return;
    }

    // Fetch twist metadata including environment
    const twistMeta = safeQuery(
      await this.supabase
        .from("twist")
        .select("environment")
        .eq("id", priorityTwist.twist_id)
        .maybeSingle(),
      {
        table: "twist",
        operation: "SELECT",
        description: "Fetch twist environment for callback error logging",
        identifiers: { twistId: priorityTwist.twist_id },
      }
    );

    // If twist was deleted, clean up callback and return
    if (!twistMeta) {
      logger.warn("Twist not found for callback, deleting callback", {
        twistId: priorityTwist.twist_id,
        token,
      });
      this.delete(token);
      return;
    }

    const factory = twistFactory({
      env: this.env,
      ctx: this.ctx,
      supabase: this.supabase,
    });
    const twistWrapper = await factory({
      version: callback.version,
      priorityId: priorityTwist.priority_id,
      priorityTwistId: callback.priorityTwistId,
    });

    // Call the callback with error handling (works for both twists and tools via path parameter)
    const callResult = await handleTwistOperation(
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
        id: String(priorityTwist.twist_id),
        version: callback.version,
        environment: twistMeta.environment,
      }
    );

    if (callback.callOnce) {
      this.delete(token);
    }

    return callResult;
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
      ...(path ? [priorityTwistId, superjson.stringify(path)] : [priorityTwistId])
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
      const extraArgs = row.extra_args
        ? this.parseWithFallback<any[]>(row.extra_args as string)
        : undefined;
      try {
        await this.callCallback(token, ...(extraArgs ?? []));
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
      throw new Error("Missing callback token");
    }

    const [id] = token.split(":");

    // Validate DO ID format before attempting to create stub
    if (!isValidDoId(id)) {
      throw new Error("Invalid callback token format");
    }

    const callbacksId = callbacks.idFromString(id);
    const callbacksStub = callbacks.get(callbacksId);
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    // Note: We don't dispose here as the caller (queue/logs.ts) will handle disposal
    return await callbacksStub.callCallback(token, ...args);
  }
}
