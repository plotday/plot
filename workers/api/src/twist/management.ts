import { type Database, type SupabaseClient, safeQuery } from "@plotday/db";

import type { twistFactory as TwistFactory } from ".";
import { type TwistEnvironment } from "../env";
import { getUser } from "../utils/auth";

export async function add(
  supabase: SupabaseClient,
  supabaseAdmin: SupabaseClient,
  priority_id: string,
  twist_id: string,
  twist_environment: TwistEnvironment,
  name?: string,
  config?: any,
  activate?: {
    twistFactory: ReturnType<typeof TwistFactory>;
    version?: string;
  }
) {
  try {
    if (!priority_id || typeof priority_id !== "string") {
      throw new Error("priority_id is required and must be a string");
    }
    if (!twist_id || typeof twist_id !== "string") {
      throw new Error("twist_id is required and must be a string");
    }
    if (!twist_environment || typeof twist_environment !== "string") {
      throw new Error("twist_environment is required and must be a string");
    }

    // Verify user has access to this twist
    const { data: hasAccess, error: accessError } = await supabase.rpc(
      "is_accessible_twist",
      {
        p_twist_id: twist_id,
        p_twist_environment: twist_environment,
        p_priority_id: priority_id,
      }
    );
    if (accessError) {
      throw new Error(`Failed to check twist access: ${accessError.message}`);
    }
    if (!hasAccess) {
      throw new Error(
        `You do not have access to twist ${twist_id} (${twist_environment}) for this priority`
      );
    }

    // Use admin client to get twist metadata
    const { name: twistName } = safeQuery(
      await supabaseAdmin
        .from("twist")
        .select("name")
        .eq("id", twist_id)
        .eq("environment", twist_environment)
        .single()
    );
    if (!twistName) {
      throw new Error(
        `Twist with id ${twist_id} (${twist_environment}) not found`
      );
    }
    name ??= twistName;

    const existingTwist = safeQuery(
      await supabase
        .from("priority_twist")
        .select("id")
        .eq("priority_id", priority_id)
        .eq("name", name)
        .is("archived_at", null)
        .maybeSingle()
    );
    if (existingTwist) {
      throw new Error(
        `Twist with name "${name}" already exists for this priority.`
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

    const twist: Database["public"]["Tables"]["priority_twist"]["Insert"] = {
      priority_id: priority_id,
      twist_id: twist_id,
      twist_environment: twist_environment as any,
      name: name,
      owner_id: priority.created_by,
    };
    if (config !== undefined) {
      twist.config = config;
    }

    const priorityTwist = safeQuery(
      await supabase.from("priority_twist").insert(twist).select().single()
    );

    // Activate twist if requested
    if (activate) {
      const twistWrapper = await activate.twistFactory({
        id: twist_id,
        environment: twist_environment,
        version: activate.version,
        priorityId: priority_id,
        priorityTwistId: priorityTwist.id,
      });
      await twistWrapper.activate({ id: priority_id });
    }

    return priorityTwist;
  } catch (error) {
    console.error("Error adding twist:", error);
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

    // Query twists that are either:
    // 1. Public (environment = 'public'), OR
    // 2. User has access via twist_access table AND
    //    - priority_access_id is NULL (can install anywhere), OR
    //    - target priority is descendant of or equal to priority_access_id
    const { data, error } = await supabase.rpc("get_accessible_twists", {
      p_priority_id: priorityId,
    });

    if (error) {
      throw error;
    }

    // Enrich twist data with publisher information
    const enrichedData = await Promise.all(
      data.map(async (twist: any) => {
        // For personal twists, author is the user themselves
        if (twist.environment === "personal") {
          // Get user info from auth.users
          const { user } = await getUser(supabase);
          return {
            ...twist,
            author_name: "You",
            author_email: user?.email || null,
            author_url: null,
          };
        }

        // For other environments, get publisher info via twist_admin
        const { data: adminData } = await supabase
          .from("twist_admin")
          .select("publisher:publisher_id(name, email, url)")
          .eq("id", twist.id)
          .single();

        if (adminData?.publisher) {
          return {
            ...twist,
            author_name: (adminData.publisher as any).name || null,
            author_email: (adminData.publisher as any).email || null,
            author_url: (adminData.publisher as any).url || null,
          };
        }

        return twist;
      })
    );

    return enrichedData;
  } catch (error) {
    console.error("Error fetching twists:", error);
    throw error;
  }
}

export async function getById(
  supabase: SupabaseClient,
  priority_twist_id: string
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("twist_id is required and must be a string");
    }

    const { data, error } = await supabase
      .from("priority_twist")
      .select("*, twist(permissions)")
      .eq("id", priority_twist_id)
      .is("archived_at", null)
      .single();

    if (error) {
      throw error;
    }

    return data;
  } catch (error) {
    console.error("Error fetching twist:", error);
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
      .from("priority_child_twist")
      .select("*, twist(permissions)")
      .eq("priority_child_id", priority_id)
      .is("archived_at", null);

    if (error) {
      throw error;
    }

    return data;
  } catch (error) {
    console.error("Error fetching twists:", error);
    throw error;
  }
}

export async function update(
  supabase: SupabaseClient,
  priority_twist_id: string,
  twist: Database["public"]["Tables"]["priority_twist"]["Update"]
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    if (twist.name !== undefined) {
      // First, get the current record to find the priority_id
      const { data: currentTwist, error: currentError } = await supabase
        .from("priority_twist")
        .select("priority_id, name")
        .eq("id", priority_twist_id)
        .is("archived_at", null)
        .single();

      if (currentError) {
        throw new Error(
          `Failed to fetch current twist: ${currentError.message}`
        );
      }

      if (!currentTwist) {
        throw new Error(
          `Priority twist with id ${priority_twist_id} not found`
        );
      }

      // Only check for duplicates if the name is actually changing
      if (twist.name !== currentTwist.name) {
        // Check if the new name already exists for this priority
        const { data: existingTwists, error: duplicateError } = await supabase
          .from("priority_twist")
          .select("id")
          .eq("priority_id", currentTwist.priority_id)
          .eq("name", twist.name)
          .neq("id", priority_twist_id) // Exclude the current record
          .is("archived_at", null);

        if (duplicateError) {
          throw new Error(
            `Failed to check for duplicate name: ${duplicateError.message}`
          );
        }

        if (existingTwists && existingTwists.length > 0) {
          throw new Error(
            `Twist with name "${twist.name}" already exists for this priority.`
          );
        }
      }
    }

    return safeQuery(
      await supabase
        .from("priority_twist")
        .update(twist)
        .eq("id", priority_twist_id)
        .select()
        .single()
    );
  } catch (error) {
    console.error("Error updating twist:", error);
    throw error;
  }
}

export async function deleteTwist(
  supabase: SupabaseClient,
  priority_twist_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof TwistFactory>;
  }
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    // Call deactivate callback if requested
    if (deactivate) {
      try {
        // Get twist metadata needed to create wrapper
        const { data: priorityTwist, error: fetchError } = await supabase
          .from("priority_twist")
          .select("twist_id, twist_environment, priority_id")
          .eq("id", priority_twist_id)
          .is("archived_at", null)
          .single();

        if (fetchError || !priorityTwist) {
          console.warn(
            `Could not fetch priority_twist ${priority_twist_id} for deactivation:`,
            fetchError?.message
          );
        } else {
          const twistWrapper = await deactivate.twistFactory({
            id: priorityTwist.twist_id,
            environment: priorityTwist.twist_environment,
            priorityId: priorityTwist.priority_id,
            priorityTwistId: priority_twist_id,
          });
          await twistWrapper.deactivate();
        }
      } catch (deactivateError) {
        // Log deactivation errors but continue with deletion
        console.error(
          "Error calling deactivate callback (continuing with deletion):",
          deactivateError
        );
      }
    }

    return safeQuery(
      await supabase
        .from("priority_twist")
        .update({ archived_at: new Date().toISOString() })
        .eq("id", priority_twist_id)
        .select()
        .single()
    );
  } catch (error) {
    console.error("Error deleting twist:", error);
    throw error;
  }
}

export async function archiveAndDeleteTwist(
  supabase: SupabaseClient,
  priority_twist_id: string,
  deactivate?: {
    twistFactory: ReturnType<typeof TwistFactory>;
  }
) {
  try {
    if (!priority_twist_id || typeof priority_twist_id !== "string") {
      throw new Error("priority_twist_id is required and must be a string");
    }

    // First, archive all activities created by this twist
    const { error: archiveError } = await supabase
      .from("activity")
      .update({ archived_at: new Date().toISOString() })
      .eq("created_by", priority_twist_id)
      .is("archived_at", null);

    if (archiveError) {
      throw new Error(`Failed to archive activities: ${archiveError.message}`);
    }

    // Then delete the twist (which also calls deactivate if provided)
    return await deleteTwist(supabase, priority_twist_id, deactivate);
  } catch (error) {
    console.error("Error archiving and deleting twist:", error);
    throw error;
  }
}
