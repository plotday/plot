import { DurableObject } from "cloudflare:workers";

import { type SupabaseClient, createClient, safeQuery } from "@plotday/db";

import { agentFactory } from "../agent";
import { type Bindings } from "../env";

export type CallbackData = {
  token: string;
  priorityAgentId: string;
  agentId: string;
  environment: string;
  path: string[]; // tool hierarchy only
  version: string; // agent version
  functionName: string;
  context?: any;
  callAt?: Date;
  callOnce?: boolean;
  expires?: Date;
};

export class Callbacks extends DurableObject<Bindings> {
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
          priority_agent_id TEXT NOT NULL,
          agent_id TEXT NOT NULL,
          environment TEXT NOT NULL,
          path TEXT NOT NULL,
          version TEXT NOT NULL,
          function_name TEXT NOT NULL,
          context TEXT,
          call_at INTEGER,
          call_once INTEGER DEFAULT 0,
          expires INTEGER
        )
      `);
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_priority_agent
        ON callbacks(priority_agent_id)
      `);
    this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_callbacks_call_at
        ON callbacks(call_at) WHERE call_at IS NOT NULL
      `);
  }

  async create({
    priorityAgentId,
    agentId,
    environment,
    path,
    version,
    functionName,
    context,
    callAt,
    callOnce,
    expires,
  }: {
    priorityAgentId: string;
    agentId: string;
    environment: string;
    path: string[]; // tool hierarchy only
    version?: string;
    functionName: string;
    context?: any;
    callAt?: Date;
    callOnce?: boolean;
    expires?: Date;
  }): Promise<string> {
    // Fetch version from database if not provided
    if (!version) {
      const { data, error } = await this.supabase
        .from("agent")
        .select("version")
        .eq("id", agentId)
        .eq("environment", environment)
        .single();

      if (error || !data?.version) {
        throw new Error(
          `Failed to fetch version for agent ${agentId} (${environment}): ${
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
          token, priority_agent_id, agent_id, environment, path, version, function_name, context, call_at, call_once, expires
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      priorityAgentId,
      agentId,
      environment,
      JSON.stringify(path),
      version,
      functionName,
      context ? JSON.stringify(context) : null,
      callAt ? callAt.getTime() : null,
      callOnce ? 1 : 0,
      expires ? expires.getTime() : null
    );

    // Update alarm if this is a scheduled callback
    if (callAt) {
      this.updateAlarm();
    }

    // Encode id in token for routing
    return `${this.ctx.id}:${token}`;
  }

  async call(token: string, args?: any): Promise<any> {
    [, token] = token.split(":");
    const result = this.sql
      .exec(
        `
          SELECT token, priority_agent_id, agent_id, environment, path, version, function_name, context, call_at, call_once, expires
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
      priorityAgentId: rawCallback.priority_agent_id,
      agentId: rawCallback.agent_id,
      environment: rawCallback.environment,
      path: JSON.parse(rawCallback.path),
      version: rawCallback.version,
      functionName: rawCallback.function_name,
      context: rawCallback.context
        ? JSON.parse(rawCallback.context)
        : undefined,
      callAt: rawCallback.call_at ? new Date(rawCallback.call_at) : undefined,
      callOnce: Boolean(rawCallback.call_once),
      expires: rawCallback.expires ? new Date(rawCallback.expires) : undefined,
    };

    // Check if callback has expired
    if (callback.expires && callback.expires < new Date()) {
      this.delete(token);
      return Promise.reject("Callback has expired");
    }

    const { agentId, environment, path } = callback;

    const agent = safeQuery(
      await this.supabase
        .from("priority_agent")
        .select("priority_id")
        .eq("id", callback.priorityAgentId)
        .single()
    );

    const factory = agentFactory(this.env, this.ctx, this.supabase);
    const agentWrapper = await factory({
      id: agentId,
      environment,
      version: callback.version,
      priorityId: agent.priority_id,
      priorityAgentId: callback.priorityAgentId,
    });

    // Call the tool or agent based on whether a path is provided
    const callResult =
      path.length > 0
        ? await agentWrapper.callTool(
            path,
            callback.functionName,
            args === undefined ? callback.context : args,
            args === undefined ? undefined : callback.context
          )
        : await agentWrapper.call(
            callback.functionName,
            args === undefined ? callback.context : args,
            args === undefined ? undefined : callback.context
          );

    if (callback.callOnce) {
      this.delete(token);
    }

    return callResult;
  }

  delete(token: string): void {
    [, token] = token.split(":");
    this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
  }

  deleteAll(
    args:
      | {
          priorityAgentId: string;
          agentId: string;
          environment: string;
          path?: string[];
          reallyDeleteEverything?: boolean;
        }
      | { reallyDeleteEverything: true }
  ): void {
    if (args.reallyDeleteEverything) {
      this.sql.exec("DELETE FROM callbacks");
      return;
    }
    const { priorityAgentId, agentId, environment, path } = args;
    this.sql.exec(
      "DELETE FROM callbacks WHERE priority_agent_id = ? AND agent_id = ? AND environment = ?" +
        (path ? " AND path = ?" : ""),
      ...(path
        ? [priorityAgentId, agentId, environment, JSON.stringify(path)]
        : [priorityAgentId, agentId, environment])
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
        SELECT token
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
        await this.call(token);
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
   * Parses the token to extract priorityAgentId, gets the correct DO stub,
   * and executes the callback.
   */
  static async call(
    callbacks: DurableObjectNamespace<Callbacks>,
    token: string,
    args?: any
  ): Promise<any> {
    const [id] = token.split(":");
    const callbacksId = callbacks.idFromString(id);
    const callbacksStub = callbacks.get(callbacksId);
    return await callbacksStub.call(token, args);
  }
}
