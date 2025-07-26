import { RpcTarget } from "cloudflare:workers";

import type {
  Activity,
  Plot as IPlot,
  LlmMessage,
  NewActivity,
  NewPriority,
  Priority,
} from "@plotday/agents";
import { type Database, type SupabaseClient, safeQuery } from "@plotday/db";

import { create as createActivity } from "./activity";

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
    if (!name) {
      const agentName = safeQuery(
        await supabase.from("agent").select("name").eq("id", agent_id).single()
      );

      if (!agentName) {
        throw new Error(`Agent with id ${agent_id} not found`);
      }

      name = agentName.name;
    }
    if (!name) {
      throw new Error("Agent name is required");
    }

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

    const agent: Database["public"]["Tables"]["priority_agent"]["Insert"] = {
      priority_id: priority_id,
      agent_id: agent_id,
      name: name,
    };
    if (config !== undefined) {
      agent.config = config;
    }

    return safeQuery(
      await supabase.from("priority_agent").insert(agent).select().single()
    );
  } catch (error) {
    console.error("Error adding agent:", error);
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
      .from("agent_x")
      .select()
      .eq("priority_child_id", priority_id);

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

function fromDbActivity(
  dbActivity: Database["public"]["Tables"]["activity"]["Row"]
): Activity {
  return {
    id: dbActivity.id,
    createdBy: dbActivity.created_by,
    doAt: dbActivity.do_at || undefined,
    doneAt: dbActivity.done_at ? new Date(dbActivity.done_at) : undefined,
    note: dbActivity.note || undefined,
    title: dbActivity.title || undefined,
    priorityId: dbActivity.priority_id,
    path: String(dbActivity.path),
    pinned: dbActivity.pinned,
  };
}

function fromDbPriority(
  dbPriority: Database["public"]["Tables"]["priority"]["Row"]
): Priority {
  return {
    id: dbPriority.id,
    title: dbPriority.title,
  };
}

export class Plot extends RpcTarget implements IPlot {
  private supabase: SupabaseClient;
  private priorityId: string;
  private priorityAgentId: string;
  private ai: Ai;

  constructor({
    supabase,
    priorityId,
    priorityAgentId,
    ai,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    ai: Ai;
  }) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.priorityAgentId = priorityAgentId;
    this.ai = ai;
  }

  async createActivity(activity: NewActivity): Promise<Activity> {
    // Convert NewActivity to database format
    const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
      created_by: this.priorityAgentId,
      priority_id: activity.priorityId || this.priorityId,
      do_at: activity.doAt || null,
      done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
      title: activity.title || null,
      note: activity.note || null,
      pinned: activity.pinned || false,
    };

    // Handle path generation based on parentId
    if (activity.parentId) {
      // Look up parent activity to get its path
      const parentResult = await this.supabase
        .from("activity")
        .select("path")
        .eq("id", activity.parentId)
        .single();

      if (parentResult.error) {
        throw new Error(
          `Parent activity not found: ${parentResult.error.message}`
        );
      }
      // Generate child path using database function
      const pathResult = await this.supabase.rpc("generate_path", {
        parent: parentResult.data.path,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbActivity.path = pathResult.data;
    }

    const dbResult = await createActivity(this.supabase, dbActivity);
    return fromDbActivity(dbResult);
  }

  async getRelatedActivities(activity: Activity): Promise<Activity[]> {
    try {
      const { data, error } = await this.supabase
        .from("activity")
        .select()
        .eq("priority_id", activity.priorityId)
        .filter("path", "cd", activity.path.split(".")[0])
        .order("created_at");
      if (error) {
        console.error(error);
        throw error;
      }
      return data.map(fromDbActivity);
    } catch (err) {
      console.error("Failed to get siblings and parents:", err);
      throw err;
    }
  }

  async promptLlm(
    messages: LlmMessage[],
    options?: { schema?: object }
  ): Promise<any> {
    const result = await this.ai.run(
      "@hf/meta-llama/meta-llama-3-8b-instruct",
      {
        messages,
        stream: false,
        max_tokens: 1024,
        ...(options?.schema && {
          response_format: {
            type: "json_schema",
            json_schema: options.schema,
          },
        }),
      }
    );
    return result;
  }

  async createPriority(priority: NewPriority): Promise<Priority> {
    if (!priority.parentId) {
      priority.parentId = this.priorityId;
    }

    const parentResult = await this.supabase
      .from("priority")
      .select("path, created_by")
      .eq("id", priority.parentId)
      .single();

    if (parentResult.error) {
      throw new Error(
        `Parent priority not found: ${parentResult.error.message}`
      );
    }

    // Generate child path using database function
    const pathResult = await this.supabase.rpc("generate_path", {
      parent: parentResult.data.path,
    });

    if (pathResult.error) {
      throw new Error(`Path generation failed: ${pathResult.error.message}`);
    }

    const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
      created_by: parentResult.data.created_by,
      title: priority.title,
      path: pathResult.data,
    };

    const result = await this.supabase
      .from("priority")
      .insert(dbPriority)
      .select()
      .single();

    if (result.error) {
      throw new Error(`Priority creation failed: ${result.error.message}`);
    }

    return fromDbPriority(result.data);
  }
}

