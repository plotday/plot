import { DurableObject } from "cloudflare:workers";

import { type SupabaseClient, createClient, safeQuery } from "@plotday/db";

import { twistFactory } from "../twist";
import { validateSerializable } from "../twist/tools/validation";
import { type TwistEnvironment, type Bindings } from "../env";

export type CallbackData = {
  token: string;
  priorityTwistId: string;
  twistId: string;
  environment: TwistEnvironment;
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

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private initializeTable() {
    this.sql.exec(`
        CREATE TABLE IF NOT EXISTS callbacks (
          token TEXT PRIMARY KEY,
          priority_twist_id TEXT NOT NULL,
          twist_id TEXT NOT NULL,
          environment TEXT NOT NULL,
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
    twistId,
    environment,
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
    twistId: string;
    environment: TwistEnvironment;
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
    if (extraArgs !== undefined) {
      validateSerializable(
        `create callback args for function "${functionName}"`,
        extraArgs
      );
    }

    // Fetch version from database if not provided
    if (!version) {
      const { data, error } = await this.supabase
        .from("twist")
        .select("version")
        .eq("id", twistId)
        .eq("environment", environment)
        .single();

      if (error || !data?.version) {
        throw new Error(
          `Failed to fetch version for twist ${twistId} (${environment}): ${
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
          token, priority_twist_id, twist_id, environment, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      priorityTwistId,
      twistId,
      environment,
      JSON.stringify(path),
      version,
      functionName,
      extraArgs ? JSON.stringify(extraArgs) : null,
      callAt ? callAt.getTime() : null,
      callOnce ? 1 : 0,
      expires ? expires.getTime() : null,
      key ?? null,
      meta ? JSON.stringify(meta) : null
    );

    // Update alarm if this is a scheduled callback
    if (callAt) {
      this.updateAlarm();
    }

    // Encode id in token for routing
    return `${this.ctx.id}:${token}`;
  }

  async callCallback(token: string, ...args: any[]): Promise<any> {
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
          SELECT token, priority_twist_id, twist_id, environment, path, version, function_name, extra_args, call_at, call_once, expires, key, meta
          FROM callbacks
          WHERE token = ?
          `,
        [token]
      )
      .next();
    if (result.done) {
      console.warn(`Callback not found for token: ${token}`);
      return Promise.reject("Callback not found");
    }
    const rawCallback = result.value as any;
    const callback: CallbackData = {
      token: rawCallback.token,
      priorityTwistId: rawCallback.priority_twist_id,
      twistId: rawCallback.twist_id,
      environment: rawCallback.environment,
      path: JSON.parse(rawCallback.path),
      version: rawCallback.version,
      functionName: rawCallback.function_name,
      extraArgs: rawCallback.extra_args
        ? JSON.parse(rawCallback.extra_args)
        : undefined,
      callAt: rawCallback.call_at ? new Date(rawCallback.call_at) : undefined,
      callOnce: Boolean(rawCallback.call_once),
      expires: rawCallback.expires ? new Date(rawCallback.expires) : undefined,
      key: rawCallback.key ?? undefined,
      meta: rawCallback.meta ? JSON.parse(rawCallback.meta) : undefined,
    };

    // Check if callback has expired
    if (callback.expires && callback.expires < new Date()) {
      this.delete(token);
      return Promise.reject("Callback has expired");
    }

    const { twistId, environment, path } = callback;

    const twist = safeQuery(
      await this.supabase
        .from("priority_twist")
        .select("priority_id")
        .eq("id", callback.priorityTwistId)
        .single()
    );

    const factory = twistFactory({
      env: this.env,
      ctx: this.ctx,
      supabase: this.supabase,
    });
    const twistWrapper = await factory({
      id: twistId,
      environment,
      version: callback.version,
      priorityId: twist.priority_id,
      priorityTwistId: callback.priorityTwistId,
    });

    // Call the callback (works for both twists and tools via path parameter)
    const callResult = await twistWrapper.callCallback(
      path,
      callback.functionName,
      ...(args ?? []),
      ...(callback.extraArgs ?? [])
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
        meta: row.meta ? JSON.parse(row.meta as string) : undefined,
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
          twistId: string;
          environment: TwistEnvironment;
          path?: string[];
          reallyDeleteEverything?: boolean;
        }
      | { reallyDeleteEverything: true }
  ): void {
    if (args.reallyDeleteEverything) {
      this.sql.exec("DELETE FROM callbacks");
      return;
    }
    const { priorityTwistId, twistId, environment, path } = args;
    this.sql.exec(
      "DELETE FROM callbacks WHERE priority_twist_id = ? AND twist_id = ? AND environment = ?" +
        (path ? " AND path = ?" : ""),
      ...(path
        ? [priorityTwistId, twistId, environment, JSON.stringify(path)]
        : [priorityTwistId, twistId, environment])
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
        ? JSON.parse(row.extra_args as string)
        : undefined;
      try {
        await this.callCallback(token, ...(extraArgs ?? []));
      } catch (error) {
        console.error(`Callback failed:`, error);
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
    const [id] = token.split(":");
    const callbacksId = callbacks.idFromString(id);
    const callbacksStub = callbacks.get(callbacksId);
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    return await callbacksStub.callCallback(token, ...args);
  }
}
