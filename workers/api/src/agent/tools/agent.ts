import type { SupabaseClient } from "@plotday/db";
import type { AgentManager as IAgent } from "@plotday/sdk/tools/agent";
import type { Callback } from "@plotday/sdk/tools/callback";

import type { Bindings } from "../../env";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { deployAgent } from "../deployment";
import { generateAgent } from "../generator";
import type { AgentSource } from "../types";
import { Tool } from "./tool";

export class Agent extends Tool implements IAgent {
  private env: Bindings;
  private ctx: ExecutionContext;
  private supabase: SupabaseClient;
  private priorityAgentId: string;
  private logSubscriptionsNamespace: DurableObjectNamespace<LogSubscriptions>;

  constructor({
    env,
    ctx,
    supabase,
    priorityAgentId,
    logSubscriptions,
  }: {
    env: Bindings;
    ctx: ExecutionContext;
    supabase: SupabaseClient;
    priorityAgentId: string;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
  }) {
    super();
    this.env = env;
    this.ctx = ctx;
    this.supabase = supabase;
    this.priorityAgentId = priorityAgentId;
    this.logSubscriptionsNamespace = logSubscriptions;
    this.ctx = ctx;
  }

  /**
   * Verifies that the user has access to the given agent admin ID.
   * @throws Error if access is denied
   */
  private async verifyAgentAccess(agentAdminId: string): Promise<void> {
    // Get priority_id from priority_agent context
    const { data: priorityAgent, error: fetchError } = await this.supabase
      .from("priority_agent")
      .select("priority_id")
      .eq("id", this.priorityAgentId)
      .is("deleted_at", null)
      .single();

    if (fetchError || !priorityAgent) {
      throw new Error(
        `Failed to fetch priority context: ${fetchError?.message}`
      );
    }

    // Verify user has access to this agent via agent_admin
    const { data: agentAdmin, error: accessError } = await this.supabase
      .from("agent_admin")
      .select("priority_id")
      .eq("id", agentAdminId)
      .maybeSingle();

    if (accessError || !agentAdmin) {
      throw new Error(
        "Access denied: You do not have permission to access this agent"
      );
    }

    // Check if user can access the agent's priority (if it has one)
    if (agentAdmin.priority_id) {
      const { data: hasAccess } = await this.supabase.rpc(
        "can_access_priority",
        {
          _priority_id: agentAdmin.priority_id,
        }
      );

      if (!hasAccess) {
        throw new Error(
          "Access denied: You do not have permission to access this agent's priority"
        );
      }
    }
  }

  async create(): Promise<string> {
    // Get priority_id from priority_agent context
    const { data: priorityAgent, error: fetchError } = await this.supabase
      .from("priority_agent")
      .select("priority_id")
      .eq("id", this.priorityAgentId)
      .is("deleted_at", null)
      .single();

    if (fetchError || !priorityAgent) {
      throw new Error(
        `Failed to fetch priority context: ${fetchError?.message}`
      );
    }

    // Generate a new agent admin UUID
    const agentAdminId = crypto.randomUUID();

    // Insert into agent_admin table (with null publisher_id for now)
    const { error } = await this.supabase.from("agent_admin").insert({
      id: agentAdminId,
      publisher_id: null,
      priority_id: priorityAgent.priority_id,
    });

    if (error) {
      throw new Error(`Failed to create agent admin: ${error.message}`);
    }

    return agentAdminId;
  }

  async generate(spec: string): Promise<AgentSource> {
    return await generateAgent({ spec, env: this.env });
  }

  async deploy(
    options:
      | {
          agentId: string;
          module: string;
          source?: never;
          environment?: "personal" | "private" | "review";
          name?: string;
          description?: string;
          dryRun?: boolean;
        }
      | {
          agentId: string;
          source: AgentSource;
          module?: never;
          environment?: "personal" | "private" | "review";
          name?: string;
          description?: string;
          dryRun?: boolean;
        }
  ): Promise<{ version: string; errors?: string[] }> {
    const {
      agentId: agentAdminId,
      module: _module,
      source: _source,
      environment = "personal",
      name,
      description,
      dryRun,
    } = options;
    // Verify user has access to deploy this agent
    await this.verifyAgentAccess(agentAdminId);

    // Check if agent already exists to determine if name is required
    const { data: existingAgent, error: existingError } = await this.supabase
      .from("agent")
      .select("name, description, user_id")
      .eq("id", agentAdminId)
      .eq("environment", environment)
      .maybeSingle();

    if (existingError) {
      throw new Error(
        `Failed to check existing agent: ${existingError.message}`
      );
    }

    // Require name for first deployment
    if (!existingAgent && !name) {
      throw new Error("name is required for first deployment");
    }

    // Get user_id for personal environment
    let userId: string | null = null;
    if (environment === "personal") {
      const {
        data: { user },
      } = await this.supabase.auth.getUser();
      if (!user) {
        throw new Error("User not authenticated");
      }
      userId = user.id;
    }

    // Use common deployment implementation
    const result = await deployAgent({
      env: this.env,
      ctx: this.ctx,
      supabase: this.supabase,
      adminId: agentAdminId,
      input: _module !== undefined ? { module: _module } : { source: _source! },
      environment,
      name: name || existingAgent?.name || "",
      description,
      userId,
      dryRun,
    });

    return {
      version: result.version,
      errors: result.errors,
    };
  }

  async watchLogs(agentAdminId: string, callback: Callback): Promise<void> {
    // Verify user has access to watch logs for this agent
    await this.verifyAgentAccess(agentAdminId);

    // Get the LogSubscriptions DO for this agent (sharded by agentAdminId)
    const logSubscriptionsId =
      this.logSubscriptionsNamespace.idFromName(agentAdminId);
    const logSubscriptions =
      this.logSubscriptionsNamespace.get(logSubscriptionsId);

    // Subscribe to logs for the provided agent admin_id
    logSubscriptions.subscribe(agentAdminId, callback);
  }
}
