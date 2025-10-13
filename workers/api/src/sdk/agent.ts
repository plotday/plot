import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import { storeAgentModule } from "../agent";
import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";

const agent = new Hono<{ Bindings: Bindings }>();

const AgentDeploymentSchema = z.object({
  module: z.string(),
  env: z.record(z.string(), z.any()).optional(),
  name: z.string().optional(),
  description: z.string().optional(),
  environment: z.enum(["personal", "private", "review"]).optional().default("personal"),
});

// PUT /agent/:id - Deploy agent
// For personal environment: no id needed, authenticated by user token
// For other environments: id is agent_admin.id (UUID), auth by user token (priority access) or publisher token
agent.put("/agent/:id", async (c) => {
  const urlAdminId = c.req.param("id"); // This is agent_admin.id for non-personal
  const userToken = c.var.userToken;
  const publisherToken = c.var.publisherToken;
  const user = c.var.user;
  const publisher = c.var.publisher;

  if (!userToken && !publisherToken) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Parse and validate request body
  const rawBody = await c.req.json();
  const parseResult = AgentDeploymentSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { module, env, name, description, environment } = parseResult.data;

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // Validate name is provided
  if (!name) {
    return new Response("Bad request: name is required", { status: 400 });
  }

  let adminId: string | null = null;
  let userId: string | null = null;

  if (environment === "personal") {
    // Personal environment: require user token
    if (!userToken || !user) {
      return new Response("Unauthorized: user token required for personal environment", {
        status: 401,
      });
    }
    userId = user.id;

    // Validate admin_id is provided
    if (!urlAdminId) {
      return new Response("Bad request: agent admin ID required", {
        status: 400,
      });
    }

    adminId = urlAdminId;

    // Check if agent_admin entry exists, create if not
    const { data: existingAdmin, error: adminCheckError } = await supabase
      .from("agent_admin")
      .select("id")
      .eq("id", adminId)
      .maybeSingle();

    if (adminCheckError) {
      console.error("Error checking agent_admin:", adminCheckError);
      return new Response(`Error checking agent_admin: ${adminCheckError.message}`, {
        status: 500,
      });
    }

    // Create agent_admin entry if it doesn't exist
    if (!existingAdmin) {
      const { error: createAdminError } = await supabase
        .from("agent_admin")
        .insert({
          id: adminId,
          publisher_id: null,
          priority_id: null,
        });

      if (createAdminError) {
        console.error("Error creating agent_admin:", createAdminError);
        return new Response(`Error creating agent_admin: ${createAdminError.message}`, {
          status: 500,
        });
      }
    }
  } else {
    // Non-personal environment: require admin_id and validate access
    if (!urlAdminId) {
      return new Response("Bad request: agent admin ID required for non-personal environment", {
        status: 400,
      });
    }

    // Validate description for non-personal
    if (!description) {
      return new Response("Bad request: description is required for non-personal deployments", {
        status: 400,
      });
    }

    adminId = urlAdminId;

    // Fetch agent_admin to validate it exists and for auth check
    const { data: agentAdmin, error: adminError } = await supabase
      .from("agent_admin")
      .select("id, publisher_id, priority_id")
      .eq("id", adminId)
      .single();

    if (adminError || !agentAdmin) {
      return new Response("Bad request: agent admin not found", { status: 404 });
    }

    // Validate that publisher_id and priority_id are set for non-personal
    if (agentAdmin.publisher_id === null || agentAdmin.priority_id === null) {
      return new Response(
        "Use the Agent Publisher agent in Plot to prepare this agent for publishing.",
        { status: 400 }
      );
    }

    // Auth check: user token must have access to priority, or publisher token must match
    if (userToken && user) {
      // Check if user has access to the admin priority
      const { data: hasAccess, error: accessError } = await supabase.rpc(
        "user_has_priority_access",
        {
          user_id: user.id,
          target_priority_id: agentAdmin.priority_id,
        }
      );

      if (accessError || !hasAccess) {
        return new Response("Forbidden: you do not have access to this agent's priority", {
          status: 403,
        });
      }
    } else if (publisherToken && publisher) {
      // Check if publisher matches
      if (publisher.id !== agentAdmin.publisher_id) {
        return new Response("Forbidden: publisher token does not match agent publisher", {
          status: 403,
        });
      }
    } else {
      return new Response("Unauthorized", { status: 401 });
    }
  }

  // Store agent module in R2
  // Use admin_id as storage key
  const storageKey = adminId!;
  let version: string;
  let dependencies: any[];
  try {
    const storeResult = await storeAgentModule(c.env, storageKey, module);
    version = storeResult.version;
    dependencies = storeResult.dependencies;
  } catch (error) {
    console.error("Error storing agent module:", error);
    return new Response(
      `Error storing agent module: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }

  // Check if agent already exists for this environment
  // Query by id and environment (compound primary key)
  const { data: existingAgent } = await supabase
    .from("agent")
    .select("name, description")
    .eq("id", adminId)
    .eq("environment", environment)
    .maybeSingle();

  if (!existingAgent) {
    // Create new agent
    const { data: newAgent, error: createError } = await supabase
      .from("agent")
      .insert({
        id: adminId,
        name,
        description,
        version,
        environment,
        user_id: userId,
      })
      .select()
      .single();

    if (createError || !newAgent) {
      console.error("Error creating agent:", createError);
      return new Response(`Error creating agent: ${createError?.message}`, {
        status: 500,
      });
    }
  } else {
    // Update existing agent
    const updateData: Record<string, any> = { version };
    if (env !== undefined) updateData.env = env;
    if (name !== undefined) updateData.name = name;
    if (description !== undefined) updateData.description = description;

    const { data: updatedAgent, error: updateError } = await supabase
      .from("agent")
      .update(updateData)
      .eq("id", adminId)
      .eq("environment", environment)
      .select()
      .single();

    if (updateError || !updatedAgent) {
      console.error("Error updating agent:", updateError);
      return new Response(`Error updating agent: ${updateError?.message}`, {
        status: 500,
      });
    }
  }

  // Module already stored in R2 at the beginning of this function
  // Fetch the final agent to return
  const { data: finalAgent, error: finalError } = await supabase
    .from("agent")
    .select("*")
    .eq("id", adminId)
    .eq("environment", environment)
    .single();

  if (finalError || !finalAgent) {
    console.error("Error fetching final agent:", finalError);
    return new Response(`Error fetching final agent: ${finalError?.message}`, {
      status: 500,
    });
  }

  // If deploying to review and auto_approve is true, also deploy to public
  if (environment === "review") {
    const { data: agentAdmin, error: adminFetchError } = await supabase
      .from("agent_admin")
      .select("auto_approve")
      .eq("id", adminId)
      .single();

    if (adminFetchError) {
      console.error("Error fetching agent_admin for auto_approve check:", adminFetchError);
    } else if (agentAdmin?.auto_approve) {
      console.log(`Auto-approving agent ${adminId} to public environment`);

      // Upsert public agent (compound key: id, environment)
      const { error: upsertPublicError } = await supabase
        .from("agent")
        .upsert(
          {
            id: adminId,
            environment: "public",
            name,
            description,
            version,
            user_id: null, // Public agents have no user_id
          },
          {
            onConflict: "id,environment",
          }
        );

      if (upsertPublicError) {
        console.error("Error auto-deploying to public:", upsertPublicError);
      } else {
        console.log(`Successfully auto-deployed agent ${adminId} to public environment`);
      }
    }
  }

  // Extract only direct dependencies (id only) for the response
  const directDependencies = dependencies.map((dep) => dep.id);

  return c.json({
    ...finalAgent,
    dependencies: directDependencies,
  });
});

export default agent;
