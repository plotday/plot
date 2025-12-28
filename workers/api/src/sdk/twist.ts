import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import { deployTwist } from "../twist/deployment";
import type { Bindings } from "../env";
import { SSEStream, acceptsSSE } from "../utils/sse";
import { handleValidationError } from "../utils/validation";

const twist = new Hono<{ Bindings: Bindings }>();

const TwistDeploymentSchema = z
  .object({
    module: z.string().optional(),
    sourcemap: z.string().optional(),
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

// POST /twist/generate - Generate twist source from specification
// This route must be defined BEFORE /twist/:id to prevent "generate" being matched as an id
twist.post("/twist/generate", async (c) => {
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

  // Generate twist source from spec
  try {
    const { generateTwist } = await import("../twist/generator");

    // Check if client wants streaming response
    const useSSE = acceptsSSE(c.req.raw);

    if (useSSE) {
      // Stream progress updates via SSE
      const stream = new SSEStream();

      // Start generation in the background
      (async () => {
        try {
          const source = await generateTwist({
            spec,
            env: c.env,
            onProgress: (message) => stream.sendProgress(message),
          });
          stream.sendResult(source);
        } catch (error) {
          console.error("Error generating twist:", error);
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
      const source = await generateTwist({ spec, env: c.env });
      return c.json(source);
    }
  } catch (error) {
    console.error("Error generating twist:", error);
    return new Response(
      `Error generating twist: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      { status: 500 }
    );
  }
});

// POST /twist/:id - Deploy twist
// For personal environment: id is twist_package_id, authenticated by user token
// For other environments: id is twist_package_id (UUID), auth by user token (priority access) or publisher token
twist.post("/twist/:id", async (c) => {
  const urlPackageId = c.req.param("id"); // This is twist_package_id
  const userToken = c.var.userToken;
  const publisherToken = c.var.publisherToken;
  const user = c.var.user;
  const publisher = c.var.publisher;

  if (!userToken && !publisherToken) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Parse and validate request body
  const rawBody = await c.req.json();
  const parseResult = TwistDeploymentSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { module, sourcemap, source, dryRun, name, description, environment } =
    parseResult.data;

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // Validate name is provided
  if (!name) {
    return new Response("Bad request: name is required", { status: 400 });
  }

  let packageId: string | null = null;
  let userId: string | null = null;
  let twistAdminId: number | null = null;

  if (environment === "personal") {
    // Personal environment: require user token
    if (!userToken || !user) {
      return new Response(
        "Unauthorized: user token required for personal environment",
        {
          status: 401,
        }
      );
    }
    userId = user.id;

    // Validate package_id is provided
    if (!urlPackageId) {
      return new Response("Bad request: twist package ID required", {
        status: 400,
      });
    }

    packageId = urlPackageId;

    // Check if twist_admin entry exists, create if not
    const { data: existingAdmin, error: adminCheckError } = await supabase
      .from("twist_admin")
      .select("id")
      .eq("twist_package_id", packageId)
      .eq("user_id", userId)
      .maybeSingle();

    if (adminCheckError) {
      console.error("Error checking twist_admin:", adminCheckError);
      return new Response(
        `Error checking twist_admin: ${adminCheckError.message}`,
        {
          status: 500,
        }
      );
    }

    if (existingAdmin) {
      twistAdminId = existingAdmin.id;
    } else {
      // Create twist_admin entry if it doesn't exist
      const { data: newAdmin, error: createAdminError } = await supabase
        .from("twist_admin")
        .insert({
          twist_package_id: packageId,
          user_id: userId,
          publisher_id: null,
          priority_id: null,
        })
        .select("id")
        .single();

      if (createAdminError || !newAdmin) {
        console.error("Error creating twist_admin:", createAdminError);
        return new Response(
          `Error creating twist_admin: ${createAdminError?.message}`,
          {
            status: 500,
          }
        );
      }
      twistAdminId = newAdmin.id;
    }
  } else {
    // Non-personal environment: require package_id and validate access
    if (!urlPackageId) {
      return new Response(
        "Bad request: twist package ID required for non-personal environment",
        {
          status: 400,
        }
      );
    }

    // Validate description for non-personal
    if (!description) {
      return new Response(
        "Bad request: description is required for non-personal deployments",
        {
          status: 400,
        }
      );
    }

    packageId = urlPackageId;

    // Fetch twist_admin to validate it exists and for auth check
    // For non-personal, user_id should be NULL
    const { data: twistAdmin, error: adminError } = await supabase
      .from("twist_admin")
      .select("id, publisher_id, priority_id, user_id")
      .eq("twist_package_id", packageId)
      .is("user_id", null)
      .single();

    if (adminError || !twistAdmin) {
      return new Response("Bad request: twist admin not found", {
        status: 404,
      });
    }

    twistAdminId = twistAdmin.id;

    // Validate that publisher_id and priority_id are set for non-personal
    if (twistAdmin.publisher_id === null || twistAdmin.priority_id === null) {
      return new Response(
        "Use the Twist Publisher twist in Plot to prepare this twist for publishing.",
        { status: 400 }
      );
    }

    // Integrations check: user token must have access to priority, or publisher token must match
    if (userToken && user) {
      // Check if user has access to the admin priority
      const { data: hasAccess, error: accessError } = await supabase.rpc(
        "user_has_priority_access",
        {
          user_id: user.id,
          target_priority_id: twistAdmin.priority_id,
        }
      );

      if (accessError || !hasAccess) {
        return new Response(
          "Forbidden: you do not have access to this twist's priority",
          {
            status: 403,
          }
        );
      }
    } else if (publisherToken && publisher) {
      // Check if publisher matches
      if (publisher.id !== twistAdmin.publisher_id) {
        return new Response(
          "Forbidden: publisher token does not match twist publisher",
          {
            status: 403,
          }
        );
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
        const result = await deployTwist({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          supabase,
          twistAdminId: twistAdminId!,
          input:
            module !== undefined
              ? { module, sourcemap }
              : { source: source! },
          environment,
          name: name!,
          description,
          userId,
          dryRun,
          onProgress: (message) => stream.sendProgress(message),
        });

        // If dryRun, return validation result with permissions
        if (dryRun) {
          stream.sendResult({
            success: !result.errors || result.errors.length === 0,
            errors: result.errors,
            permissions: result.permissions,
          });
          return;
        }

        // Fetch the final twist to return
        const { data: finalTwist, error: finalError } = await supabase
          .from("twist")
          .select("*")
          .eq("twist_admin_id", twistAdminId)
          .eq("environment", environment)
          .single();

        if (finalError || !finalTwist) {
          console.error("Error fetching final twist:", finalError);
          stream.sendError(
            `Error fetching final twist: ${finalError?.message}`
          );
          return;
        }

        stream.sendResult({
          ...finalTwist,
          permissions: result.permissions,
        });
      } catch (error) {
        console.error("Error deploying twist:", error);
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
    let result;
    try {
      result = await deployTwist({
        env: c.env,
        ctx: c.executionCtx as ExecutionContext,
        supabase,
        twistAdminId: twistAdminId!,
        input:
          module !== undefined ? { module, sourcemap } : { source: source! },
        environment,
        name: name!,
        description,
        userId,
        dryRun,
      });
    } catch (error) {
      console.error("Error deploying twist:", error);
      return new Response(
        `Error deploying twist: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
        { status: 500 }
      );
    }

    // If dryRun, return validation result with permissions
    if (dryRun) {
      return c.json({
        success: !result.errors || result.errors.length === 0,
        errors: result.errors,
        permissions: result.permissions,
      });
    }

    // Fetch the final twist to return
    const { data: finalTwist, error: finalError } = await supabase
      .from("twist")
      .select("*")
      .eq("twist_admin_id", twistAdminId)
      .eq("environment", environment)
      .single();

    if (finalError || !finalTwist) {
      console.error("Error fetching final twist:", finalError);
      return new Response(
        `Error fetching final twist: ${finalError?.message}`,
        {
          status: 500,
        }
      );
    }

    return c.json({
      ...finalTwist,
      permissions: result.permissions,
    });
  }
});

// GET /twist/:id/logs - Stream twist logs via SSE
twist.get("/twist/:id/logs", async (c) => {
  const twistPackageId = c.req.param("id");
  const environment = c.req.query("environment") || "personal";
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Validate environment
  if (!["personal", "private", "review", "public"].includes(environment)) {
    return new Response("Invalid environment", { status: 400 });
  }

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // For personal environment, verify twist exists and user owns it
  // For other environments, verify user has access to the twist's priority
  if (environment === "personal") {
    // Check if twist_admin exists for this user and package
    const { data: twistAdmin, error: adminError } = await supabase
      .from("twist_admin")
      .select("id")
      .eq("twist_package_id", twistPackageId)
      .eq("user_id", user.id)
      .maybeSingle();

    if (adminError || !twistAdmin) {
      return new Response("Twist not found", { status: 404 });
    }
  } else {
    // For non-personal environments, check priority access
    const { data: twistAdmin, error: adminError } = await supabase
      .from("twist_admin")
      .select("id, priority_id")
      .eq("twist_package_id", twistPackageId)
      .is("user_id", null)
      .single();

    if (adminError || !twistAdmin) {
      return new Response("Twist not found", { status: 404 });
    }

    if (!twistAdmin.priority_id) {
      return new Response("Twist has no associated priority", { status: 400 });
    }

    // Check if user has access to the priority
    const { data: hasAccess, error: accessError } = await supabase.rpc(
      "user_has_priority_access",
      {
        user_id: user.id,
        target_priority_id: twistAdmin.priority_id,
      }
    );

    if (accessError || !hasAccess) {
      return new Response("Forbidden: you do not have access to this twist", {
        status: 403,
      });
    }
  }

  // Check if LOG_STREAM binding is configured
  if (!c.env.LOG_STREAM) {
    return new Response(
      "Log streaming is not configured. Please configure the LOG_STREAM Durable Object binding.",
      { status: 503 }
    );
  }

  // Get the LogStream Durable Object for this twist
  const logStreamId = c.env.LOG_STREAM.idFromName(twistPackageId);
  const logStream = c.env.LOG_STREAM.get(logStreamId);

  // Generate unique stream ID for this client
  const streamId = `${user.id}-${Date.now()}-${Math.random()
    .toString(36)
    .substring(7)}`;

  // Forward the request to the LogStream DO with the stream ID
  const streamUrl = new URL(c.req.url);
  streamUrl.searchParams.set("streamId", streamId);

  return logStream.fetch(streamUrl.toString());
});

export default twist;
