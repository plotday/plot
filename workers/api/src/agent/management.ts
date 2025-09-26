import { type Database, type SupabaseClient, safeQuery } from "@plotday/db";

export async function add(
  supabase: SupabaseClient,
  priority_id: string,
  agent_id: string,
  name?: string,
  config?: any
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }
    if (!agent_id || typeof agent_id !== "string") {
      throw new Error("agent_id is required and must be a string");
    }

    const { name: agentName, tools } = safeQuery(
      await supabase
        .from("agent")
        .select("name,tools")
        .eq("id", agent_id)
        .single()
    );
    if (!agentName) {
      throw new Error(`Agent with id ${agent_id} not found`);
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

    console.log("!!! priority_id", priority_id);
    const agent: Database["public"]["Tables"]["priority_agent"]["Insert"] = {
      priority_id: priority_id,
      agent_id: agent_id,
      name: name,
    };
    if (config !== undefined) {
      agent.config = config;
    }

    const priorityAgent = safeQuery(
      await supabase.from("priority_agent").insert(agent).select().single()
    );

    return {
      ...priorityAgent,
      tools,
    };
  } catch (error) {
    console.error("Error adding agent:", error);
    if (error instanceof Error) {
      console.log(error.stack);
    }
    throw error;
  }
}

export async function getAll(supabase: SupabaseClient) {
  try {
    const { data, error } = await supabase.from("agent").select();

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
