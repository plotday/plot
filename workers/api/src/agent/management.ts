import { type Database, type SupabaseClient, safeQuery } from "@plotday/db";

import type { agentFactory as AgentFactory } from ".";

export async function add(
  supabase: SupabaseClient,
  supabaseAdmin: SupabaseClient,
  priority_id: string,
  agent_id: string,
  agent_environment: "personal" | "private" | "review" | "public",
  name?: string,
  config?: any,
  activate?: {
    agentFactory: ReturnType<typeof AgentFactory>;
    version?: string;
  }
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }
    if (!agent_id || typeof agent_id !== "string") {
      throw new Error("agent_id is required and must be a string");
    }
    if (!agent_environment || typeof agent_environment !== "string") {
      throw new Error("agent_environment is required and must be a string");
    }

    // Verify user has access to this agent
    const { data: hasAccess, error: accessError } = await supabase.rpc(
      "is_accessible_agent",
      {
        p_agent_id: agent_id,
        p_agent_environment: agent_environment,
        p_priority_id: priority_id,
      }
    );
    if (accessError) {
      throw new Error(`Failed to check agent access: ${accessError.message}`);
    }
    if (!hasAccess) {
      throw new Error(
        `You do not have access to agent ${agent_id} (${agent_environment}) for this priority`
      );
    }

    // Use admin client to get agent metadata
    const { name: agentName } = safeQuery(
      await supabaseAdmin
        .from("agent")
        .select("name")
        .eq("id", agent_id)
        .eq("environment", agent_environment)
        .single()
    );
    if (!agentName) {
      throw new Error(
        `Agent with id ${agent_id} (${agent_environment}) not found`
      );
    }
    name ??= agentName;

    const existingAgent = safeQuery(
      await supabase
        .from("priority_agent")
        .select("id")
        .eq("priority_id", priority_id)
        .eq("name", name)
        .is("deleted_at", null)
        .maybeSingle()
    );
    if (existingAgent) {
      throw new Error(
        `Agent with name "${name}" already exists for this priority.`
      );
    }

    // Get owner_id from priority (using created_by as owner)
    const { data: priority } = await supabase
      .from("priority")
      .select("created_by")
      .eq("id", priority_id)
      .single();

    if (!priority?.created_by) {
      throw new Error("Priority not found or missing created_by");
    }

    const agent: Database["public"]["Tables"]["priority_agent"]["Insert"] = {
      priority_id: priority_id,
      agent_id: agent_id,
      agent_environment: agent_environment as any,
      name: name,
      owner_id: priority.created_by,
    };
    if (config !== undefined) {
      agent.config = config;
    }

    const priorityAgent = safeQuery(
      await supabase.from("priority_agent").insert(agent).select().single()
    );

    // Activate agent if requested
    if (activate) {
      const agentWrapper = await activate.agentFactory({
        id: agent_id,
        environment: agent_environment,
        version: activate.version,
        priorityId: priority_id,
        priorityAgentId: priorityAgent.id,
      });
      await agentWrapper.activate({ id: priority_id });
    }

    return priorityAgent;
  } catch (error) {
    console.error("Error adding agent:", error);
    if (error instanceof Error) {
      console.log(error.stack);
    }
    throw error;
  }
}

export async function getAll(supabase: SupabaseClient, priorityId: string) {
  try {
    if (!priorityId || typeof priorityId !== "string") {
      throw new Error("priorityId is required and must be a string");
    }

    // Query agents that are either:
    // 1. Public (environment = 'public'), OR
    // 2. User has access via agent_access table AND
    //    - priority_access_id is NULL (can install anywhere), OR
    //    - target priority is descendant of or equal to priority_access_id
    const { data, error } = await supabase.rpc("get_accessible_agents", {
      p_priority_id: priorityId,
    });

    if (error) {
      throw error;
    }

    return data;
  } catch (error) {
    console.error("Error fetching agents:", error);
    throw error;
  }
}

export async function getById(
  supabase: SupabaseClient,
  priority_agent_id: string
) {
  try {
    if (!priority_agent_id || typeof priority_agent_id !== "string") {
      throw new Error("agent_id is required and must be a string");
    }

    const { data, error } = await supabase
      .from("priority_agent")
      .select()
      .eq("id", priority_agent_id)
      .is("deleted_at", null)
      .single();

    if (error) {
      throw error;
    }

    return data;
  } catch (error) {
    console.error("Error fetching agent:", error);
    throw error;
  }
}

export async function getByPriority(
  supabase: SupabaseClient,
  priority_id: string
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }

    const { data, error } = await supabase
      .from("priority_child_agent")
      .select()
      .eq("priority_child_id", priority_id)
      .is("deleted_at", null);

    if (error) {
      throw error;
    }

    return data;
  } catch (error) {
    console.error("Error fetching agents:", error);
    throw error;
  }
}

export async function update(
  supabase: SupabaseClient,
  priority_agent_id: string,
  agent: Database["public"]["Tables"]["priority_agent"]["Update"]
) {
  try {
    if (!priority_agent_id || typeof priority_agent_id !== "string") {
      throw new Error("priority_agent_id is required and must be a string");
    }

    if (agent.name !== undefined) {
      // First, get the current record to find the priority_id
      const { data: currentAgent, error: currentError } = await supabase
        .from("priority_agent")
        .select("priority_id, name")
        .eq("id", priority_agent_id)
        .is("deleted_at", null)
        .single();

      if (currentError) {
        throw new Error(
          `Failed to fetch current agent: ${currentError.message}`
        );
      }

      if (!currentAgent) {
        throw new Error(
          `Priority agent with id ${priority_agent_id} not found`
        );
      }

      // Only check for duplicates if the name is actually changing
      if (agent.name !== currentAgent.name) {
        // Check if the new name already exists for this priority
        const { data: existingAgents, error: duplicateError } = await supabase
          .from("priority_agent")
          .select("id")
          .eq("priority_id", currentAgent.priority_id)
          .eq("name", agent.name)
          .neq("id", priority_agent_id) // Exclude the current record
          .is("deleted_at", null);

        if (duplicateError) {
          throw new Error(
            `Failed to check for duplicate name: ${duplicateError.message}`
          );
        }

        if (existingAgents && existingAgents.length > 0) {
          throw new Error(
            `Agent with name "${agent.name}" already exists for this priority.`
          );
        }
      }
    }

    return safeQuery(
      await supabase
        .from("priority_agent")
        .update(agent)
        .eq("id", priority_agent_id)
        .select()
        .single()
    );
  } catch (error) {
    console.error("Error updating agent:", error);
    throw error;
  }
}

export async function deleteAgent(
  supabase: SupabaseClient,
  priority_agent_id: string
) {
  try {
    if (!priority_agent_id || typeof priority_agent_id !== "string") {
      throw new Error("priority_agent_id is required and must be a string");
    }

    return safeQuery(
      await supabase
        .from("priority_agent")
        .update({ deleted_at: new Date().toISOString() })
        .eq("id", priority_agent_id)
        .select()
        .single()
    );
  } catch (error) {
    console.error("Error deleting agent:", error);
    throw error;
  }
}
