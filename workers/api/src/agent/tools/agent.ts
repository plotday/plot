import type { SupabaseClient } from "@plotday/db";
import type { AgentManager as IAgent } from "@plotday/sdk/tools/agent";
import type { Callback } from "@plotday/sdk/tools/callback";

import { type LogSubscriptions } from "../../state/log-subscriptions";
import { Tool } from "./tool";

export class Agent extends Tool implements IAgent {
  private supabase: SupabaseClient;
  private priorityAgentId: string;
  private logSubscriptionsNamespace: DurableObjectNamespace<LogSubscriptions>;

  constructor({
    supabase,
    priorityAgentId,
    logSubscriptions,
  }: {
    supabase: SupabaseClient;
    priorityAgentId: string;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
  }) {
    super();
    this.supabase = supabase;
    this.priorityAgentId = priorityAgentId;
    this.logSubscriptionsNamespace = logSubscriptions;
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

  async deploy({
    agentId: agentAdminId,
    module: _module,
    environment = "personal",
    name,
    description,
  }: {
    agentId: string;
    module: string;
    environment?: "personal" | "private" | "review";
    name?: string;
    description?: string;
  }): Promise<{ version: string }> {
    // Verify user has access to deploy this agent
    await this.verifyAgentAccess(agentAdminId);

    // Check if agent already exists with this id and environment (compound key)
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

    // Generate timestamp version
    const version = Date.now().toString();

    if (!existingAgent) {
      // First deploy: Create new agent
      if (!name || !description) {
        throw new Error(
          "name and description are required for first deployment"
        );
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

      const { data: newAgent, error: createError } = await this.supabase
        .from("agent")
        .insert({
          id: agentAdminId,
          name,
          description,
          version,
          environment,
          user_id: userId,
        })
        .select()
        .single();

      if (createError || !newAgent) {
        throw new Error(`Failed to create agent: ${createError?.message}`);
      }
    } else {
      // Update existing agent for this environment
      const updateData: Record<string, any> = { version };
      if (name !== undefined) updateData.name = name;
      if (description !== undefined) updateData.description = description;

      const { data: updatedAgent, error: updateError } = await this.supabase
        .from("agent")
        .update(updateData)
        .eq("id", agentAdminId)
        .eq("environment", environment)
        .select()
        .single();

      if (updateError || !updatedAgent) {
        throw new Error(`Failed to update agent: ${updateError?.message}`);
      }
    }

    // Note: Module storage in R2 is handled by the API endpoint
    // This tool is meant to be called from within the agent context,
    // not as a replacement for the HTTP API

    return {
      version,
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
