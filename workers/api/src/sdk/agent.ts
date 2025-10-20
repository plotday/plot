import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import { deployAgent } from "../agent/deployment";
import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";
import { SSEStream, acceptsSSE } from "../utils/sse";

const agent = new Hono<{ Bindings: Bindings }>();

const AgentDeploymentSchema = z
  .object({
    module: z.string().optional(),
    source: z
      .object({
        displayName: z.string(),
        dependencies: z.record(z.string(), z.string()),
        files: z.record(z.string(), z.string()),
      })
      .optional(),
    dryRun: z.boolean().optional(),
    env: z.record(z.string(), z.any()).optional(),
    name: z.string().optional(),
    description: z.string().optional(),
    environment: z
      .enum(["personal", "private", "review"])
      .optional()
      .default("personal"),
  })
  .refine(
    (data) => (data.module !== undefined) !== (data.source !== undefined),
    {
      message: "Exactly one of 'module' or 'source' must be provided",
    }
  );

// POST /agent/generate - Generate agent source from specification
// This route must be defined BEFORE /agent/:id to prevent "generate" being matched as an id
agent.post("/agent/generate", async (c) => {
  const userToken = c.var.userToken;
  const publisherToken = c.var.publisherToken;

  if (!userToken && !publisherToken) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Parse and validate request body
  const rawBody = await c.req.json();
  const parseResult = z
    .object({
      spec: z.string(),
    })
    .safeParse(rawBody);

  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { spec } = parseResult.data;

  if (!spec || spec.trim().length === 0) {
    return new Response("Bad request: spec cannot be empty", { status: 400 });
  }

  // Generate agent source from spec
  try {
    const { generateAgent } = await import("../agent/generator");

    // Check if client wants streaming response
    const useSSE = acceptsSSE(c.req.raw);

    if (useSSE) {
      // Stream progress updates via SSE
      const stream = new SSEStream();

      // Start generation in the background
      (async () => {
        try {
          const source = await generateAgent({
            spec,
            env: c.env,
            onProgress: (message) => stream.sendProgress(message),
          });
          stream.sendResult(source);
        } catch (error) {
          console.error("Error generating agent:", error);
          stream.sendError(
            error instanceof Error ? error.message : "Unknown error"
          );
        } finally {
          stream.close();
        }
      })();

      return stream.toResponse();
    } else {
      // Return JSON response (no progress updates)
      const source = await generateAgent({ spec, env: c.env });
      return c.json(source);
    }
  } catch (error) {
    console.error("Error generating agent:", error);
    return new Response(
      `Error generating agent: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

// POST /agent/:id - Deploy agent
// For personal environment: no id needed, authenticated by user token
// For other environments: id is agent_admin.id (UUID), auth by user token (priority access) or publisher token
agent.post("/agent/:id", async (c) => {
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

  const { module, source, dryRun, name, description, environment } =
    parseResult.data;

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

  // Check if client wants streaming response
  const useSSE = acceptsSSE(c.req.raw);

  if (useSSE) {
    // Stream progress updates via SSE
    const stream = new SSEStream();

    // Start deployment in the background
    (async () => {
      try {
        const result = await deployAgent({
          env: c.env,
          supabase,
          adminId: adminId!,
          input: module !== undefined ? { module } : { source: source! },
          environment,
          name: name!,
          description,
          userId,
          dryRun,
          onProgress: (message) => stream.sendProgress(message),
        });

        // If dryRun, return validation result
        if (dryRun) {
          stream.sendResult({
            success: !result.errors || result.errors.length === 0,
            errors: result.errors,
          });
          return;
        }

        // Fetch the final agent to return
        const { data: finalAgent, error: finalError } = await supabase
          .from("agent")
          .select("*")
          .eq("id", adminId)
          .eq("environment", environment)
          .single();

        if (finalError || !finalAgent) {
          console.error("Error fetching final agent:", finalError);
          stream.sendError(`Error fetching final agent: ${finalError?.message}`);
          return;
        }

        stream.sendResult({
          ...finalAgent,
          dependencies: result.dependencies,
        });
      } catch (error) {
        console.error("Error deploying agent:", error);
        stream.sendError(
          error instanceof Error ? error.message : "Unknown error"
        );
      } finally {
        stream.close();
      }
    })();

    return stream.toResponse();
  } else {
    // Non-streaming JSON response
    let dependencies: string[];
    let errors: string[] | undefined;
    try {
      const result = await deployAgent({
        env: c.env,
        supabase,
        adminId: adminId!,
        input: module !== undefined ? { module } : { source: source! },
        environment,
        name: name!,
        description,
        userId,
        dryRun,
      });
      dependencies = result.dependencies;
      errors = result.errors;
    } catch (error) {
      console.error("Error deploying agent:", error);
      return new Response(
        `Error deploying agent: ${error instanceof Error ? error.message : "Unknown error"}`,
        { status: 500 }
      );
    }

    // If dryRun, return validation result
    if (dryRun) {
      return c.json({
        success: !errors || errors.length === 0,
        errors,
      });
    }

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

    return c.json({
      ...finalAgent,
      dependencies,
    });
  }
});

export default agent;
