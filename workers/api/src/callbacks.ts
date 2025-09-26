import { DurableObject } from "cloudflare:workers";

import { type SupabaseClient, createClient, safeQuery } from "@plotday/db";

import {
  type ToolDependencySpec,
  agentFactory,
  createTool,
  createTools,
} from "./agent";
import { type Bindings } from "./env";

export type CallbackData = {
  token: string;
  priorityAgentId: string;
  path: string[]; // agentId followed by toolIds
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
          path TEXT NOT NULL,
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

  create({
    priorityAgentId,
    path,
    functionName,
    context,
    callAt,
    callOnce,
    expires,
  }: {
    priorityAgentId: string;
    path: string[]; // agentId followed by toolIds
    functionName: string;
    context?: any;
    callAt?: Date;
    callOnce?: boolean;
    expires?: Date;
  }): string {
    if (path.length === 0) {
      throw new Error("Path must contain at least the agent ID");
    }

    const token = this.generateToken();

    // Default callOnce to true if callAt is specified, false otherwise
    callOnce ??= callAt !== undefined;

    this.sql.exec(
      `
        INSERT INTO callbacks (
          token, priority_agent_id, path, function_name, context, call_at, call_once, expires
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      priorityAgentId,
      JSON.stringify(path),
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

    return token;
  }

  async call(token: string, args?: any): Promise<any> {
    const result = this.sql
      .exec(
        `
          SELECT token, priority_agent_id, path, function_name, context, call_at, call_once, expires
          FROM callbacks 
          WHERE token = ?
          `,
        [token]
      )
      .next();
    if (result.done) {
      return Promise.reject("Callback not found");
    }
    const rawCallback = result.value as any;
    const callback: CallbackData = {
      token: rawCallback.token,
      priorityAgentId: rawCallback.priority_agent_id,
      path: JSON.parse(rawCallback.path),
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

    const [agentId, ...path] = callback.path;

    const agent = safeQuery(
      await this.supabase
        .from("priority_agent")
        .select("priority_id,agent(tools)")
        .eq("id", callback.priorityAgentId)
        .single()
    );
    let dependencies = agent.agent!.tools as ToolDependencySpec[];
    let tool: ToolDependencySpec | undefined;
    // navigate to the correct tool if a path is provided
    for (const pathId of path) {
      tool = dependencies.find((tool) => tool.id === pathId);
      if (!tool) {
        throw new Error(`Path ${path} not found in agent ${agentId} tools`);
      }
      dependencies = tool.tools ?? [];
    }

    // Create tools needed for the callback
    const agents = agentFactory(this.env);
    const callResult = tool
      ? await agents(agentId).callTool(
          createTool(callback.path, tool, {
            supabase: this.supabase,
            ai: this.env.AI,
            priorityId: agent.priority_id,
            priorityAgentId: callback.priorityAgentId,
            storage: this.env.STORAGE,
            callbacks: this.env.CALLBACKS,
            env: this.env,
            agents,
          }),
          callback.functionName,
          args === undefined ? callback.context : args,
          args === undefined ? undefined : callback.context
        )
      : await agents(agentId).call(
          createTools(
            {
              path: callback.path,
              dependencies,
            },
            {
              supabase: this.supabase,
              ai: this.env.AI,
              priorityId: agent.priority_id,
              priorityAgentId: callback.priorityAgentId,
              storage: this.env.STORAGE,
              callbacks: this.env.CALLBACKS,
              env: this.env,
              agents,
            }
          ),
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
    this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
  }

  deleteAll(
    args:
      | {
          priorityAgentId: string;
          path?: string[];
          reallyDeleteEverything?: boolean;
        }
      | { reallyDeleteEverything: true }
  ): void {
    if (args.reallyDeleteEverything) {
      this.sql.exec("DELETE FROM callbacks");
      return;
    }
    const { priorityAgentId, path } = args;
    this.sql.exec(
      "DELETE FROM callbacks WHERE priority_agent_id = ?" +
        (path ? " AND path = ?" : ""),
      ...(path ? [priorityAgentId, JSON.stringify(path)] : [priorityAgentId])
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
}
