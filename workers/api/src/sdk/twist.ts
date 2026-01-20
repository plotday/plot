import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { deployTwist } from "../twist/deployment";
import {
  createPublisher,
  getAccessiblePublishers,
  getOrCreateTwistPriority,
} from "../twist/priority-management";
import { SSEStream, acceptsSSE } from "../utils/sse";
import { handleValidationError } from "../utils/validation";
import { createLogger } from "../utils/logger";
import { deploymentRateLimiter } from "../middleware/rate-limit";

const twist = new Hono<{ Bindings: Bindings }>();

const MAX_MODULE_SIZE = 10 * 1024 * 1024; // 10 MB in bytes

// GET /twist/user - Get current user information
twist.get("/twist/user", async (c) => {
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  return c.json({
    id: user.id,
    email: user.email,
    // Extract name from user metadata, fallback to email username
    name:
      user.user_metadata?.name ||
      user.user_metadata?.full_name ||
      user.email?.split("@")[0] ||
      "User",
  });
});

const TwistDeploymentSchema = z
  .object({
    module: z
      .string()
      .max(MAX_MODULE_SIZE, "Module size exceeds 10 MB limit")
      .optional(),
    sourcemap: z
      .string()
      .max(MAX_MODULE_SIZE, "Sourcemap size exceeds 10 MB limit")
      .optional(),
    source: z
      .object({
        displayName: z.string(),
        dependencies: z.record(z.string(), z.string()),
        files: z.record(z.string(), z.string()),
      })
      .refine(
        (data) => {
          // Calculate total size of all files
          const totalSize = Object.values(data.files).reduce(
            (sum, content) => sum + content.length,
            0
          );
          return totalSize <= MAX_MODULE_SIZE;
        },
        {
          message: "Total source files size exceeds 10 MB limit",
        }
      )
      .optional(),
    dryRun: z.boolean().optional(),
    env: z.record(z.string(), z.any()).optional(),
    name: z.string().optional(),
    description: z.string().optional(),
    publisherId: z.number().optional(),
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

// GET /twist/publishers - List publishers accessible to current user
twist.get("/twist/publishers", async (c) => {
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  try {
    const publishers = await getAccessiblePublishers(user.id, supabase);
    return c.json(publishers);
  } catch (error) {
    const logger = createLogger();
    logger.error("Error fetching publishers", error as Error, { user_id: user.id });
    return new Response(
      `Error fetching publishers: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      { status: 500 }
    );
  }
});

// POST /twist/publishers - Create new publisher
twist.post("/twist/publishers", async (c) => {
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Parse and validate request body
  const rawBody = await c.req.json();
  const parseResult = z
    .object({
      name: z.string().min(1),
      url: z.string().url().nullable().optional(),
    })
    .safeParse(rawBody);

  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { name, url } = parseResult.data;

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  try {
    const publisher = await createPublisher(name, url || null, supabase);
    return c.json(publisher);
  } catch (error) {
    const logger = createLogger();
    logger.error("Error creating publisher", error as Error, {
      user_id: user.id,
      publisher_name: name
    });
    return new Response(
      `Error creating publisher: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      { status: 500 }
    );
  }
});

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
          const logger = createLogger();
          logger.error("Error generating twist", error as Error, { spec_length: spec.length });
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
    const logger = createLogger();
    logger.error("Error generating twist", error as Error, { spec_length: spec.length });
    return new Response(
      `Error generating twist: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      { status: 500 }
    );
  }
});

// GET /twist/:id - Get published twist information
// Returns twist_admin info for non-personal deployments
// Returns 404 if twist is not published (no non-personal twist_admin exists)
twist.get("/twist/:id", async (c) => {
  const twistPackageId = c.req.param("id");
  const userToken = c.var.userToken;

  if (!userToken) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // Query twist_admin for non-personal deployment (user_id IS NULL)
  const { data: twistAdmin, error: adminError } = await supabase
    .from("twist_admin")
    .select(
      `
      id,
      twist_package_id,
      priority_id,
      created_at,
      updated_at,
      publisher:publisher_id (
        id,
        name,
        email,
        url
      )
    `
    )
    .eq("twist_package_id", twistPackageId)
    .is("user_id", null)
    .maybeSingle();

  if (adminError) {
    const logger = createLogger();
    logger.error("Error fetching twist admin", adminError as Error, {
      twist_package_id: twistPackageId
    });
    return new Response(`Error fetching twist: ${adminError.message}`, {
      status: 500,
    });
  }

  if (!twistAdmin) {
    return new Response("Twist not published", { status: 404 });
  }

  return c.json({
    id: twistAdmin.id,
    twist_package_id: twistAdmin.twist_package_id,
    priority_id: twistAdmin.priority_id,
    publisher: twistAdmin.publisher as any,
    created_at: twistAdmin.created_at,
    updated_at: twistAdmin.updated_at,
  });
});

// POST /twist/:id - Deploy twist
// For personal environment: id is twist_package_id, authenticated by user token
// For other environments: id is twist_package_id (UUID), auth by user token (priority access) or publisher token
// Apply rate limiting to prevent deployment abuse (30 deployments per hour)
twist.post("/twist/:id", deploymentRateLimiter, async (c) => {
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

  const {
    module,
    sourcemap,
    source,
    dryRun,
    name,
    description,
    publisherId,
    environment,
  } = parseResult.data;

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

    // Get or create twist priority and admin entry
    try {
      const result = await getOrCreateTwistPriority(
        userId,
        packageId,
        name,
        true, // isPersonal
        supabase
      );
      twistAdminId = result.twistAdminId;
    } catch (error) {
      const logger = createLogger();
      logger.error("Error setting up twist priority", error as Error, {
        user_id: userId,
        package_id: packageId,
        twist_name: name
      });
      return new Response(
        `Error setting up twist priority: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
        {
          status: 500,
        }
      );
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

    // Get or create twist priority and admin entry for non-personal
    // This requires a user to set up the priority structure
    let twistAdmin;
    try {
      // First check if admin entry exists
      const { data: existingAdmin, error: adminError } = await supabase
        .from("twist_admin")
        .select("id, publisher_id, priority_id")
        .eq("twist_package_id", packageId)
        .is("user_id", null)
        .maybeSingle();

      if (adminError) {
        throw new Error(`Failed to query twist_admin: ${adminError.message}`);
      }

      if (existingAdmin) {
        // Admin exists, check if we need to create/update priority
        if (!existingAdmin.priority_id) {
          // Priority not set, create it
          if (!user) {
            return new Response(
              "User authentication required to set up twist priority",
              { status: 401 }
            );
          }

          // For non-personal deployments, publisherId is required
          if (publisherId === undefined) {
            return new Response(
              "Publisher ID is required for non-personal deployments",
              { status: 400 }
            );
          }

          const result = await getOrCreateTwistPriority(
            user.id,
            packageId,
            name,
            false, // isPersonal
            supabase,
            publisherId
          );
          twistAdminId = result.twistAdminId;

          // Re-fetch admin to get publisher_id
          const { data: updatedAdmin, error: refetchError } = await supabase
            .from("twist_admin")
            .select("id, publisher_id, priority_id")
            .eq("id", result.twistAdminId)
            .single();

          if (refetchError || !updatedAdmin) {
            throw new Error(
              `Failed to fetch updated admin: ${refetchError?.message}`
            );
          }
          twistAdmin = updatedAdmin;
        } else {
          twistAdminId = existingAdmin.id;

          // If publisherId was provided and differs from current, update it
          if (
            publisherId !== undefined &&
            publisherId !== existingAdmin.publisher_id
          ) {
            const { error: updateError } = await supabase
              .from("twist_admin")
              .update({ publisher_id: publisherId })
              .eq("id", existingAdmin.id);

            if (updateError) {
              throw new Error(
                `Failed to update publisher: ${updateError.message}`
              );
            }

            // Re-fetch to get updated publisher_id
            const { data: updatedAdmin, error: refetchError } = await supabase
              .from("twist_admin")
              .select("id, publisher_id, priority_id")
              .eq("id", existingAdmin.id)
              .single();

            if (refetchError || !updatedAdmin) {
              throw new Error(
                `Failed to fetch updated admin: ${refetchError?.message}`
              );
            }
            twistAdmin = updatedAdmin;
          } else {
            twistAdmin = existingAdmin;
          }
        }
      } else {
        // Admin doesn't exist, create it
        if (!user) {
          return new Response(
            "User authentication required to set up new twist",
            { status: 401 }
          );
        }

        // For non-personal deployments, publisherId is required
        if (publisherId === undefined) {
          return new Response(
            "Publisher ID is required for non-personal deployments",
            { status: 400 }
          );
        }

        const result = await getOrCreateTwistPriority(
          user.id,
          packageId,
          name,
          false, // isPersonal
          supabase,
          publisherId
        );
        twistAdminId = result.twistAdminId;

        // Fetch the new admin entry
        const { data: newAdmin, error: fetchError } = await supabase
          .from("twist_admin")
          .select("id, publisher_id, priority_id")
          .eq("id", result.twistAdminId)
          .single();

        if (fetchError || !newAdmin) {
          throw new Error(`Failed to fetch new admin: ${fetchError?.message}`);
        }
        twistAdmin = newAdmin;
      }
    } catch (error) {
      const logger = createLogger();
      logger.error("Error setting up twist for non-personal", error as Error, {
        package_id: packageId,
        twist_name: name,
        environment
      });
      return new Response(
        `Error setting up twist: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
        { status: 500 }
      );
    }

    // Validate that publisher_id is set for non-personal deployments
    if (twistAdmin.publisher_id === null) {
      return new Response(
        "Publisher is required for non-personal deployments. Use the CLI to set up a publisher.",
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
          target_priority_id: twistAdmin.priority_id!,
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
    const deploymentPromise = (async () => {
      let resultSent = false;
      try {
        const result = await deployTwist({
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
          userName: user?.user_metadata?.name || user?.user_metadata?.full_name || user?.email?.split("@")[0],
          userEmail: user?.email,
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
          resultSent = true;
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
          const logger = createLogger();
          logger.error("Error fetching deployed twist", finalError as Error, {
            twist_admin_id: twistAdminId,
            environment
          });
          stream.sendError(
            "Deployment succeeded, but failed to retrieve twist details. Please try refreshing."
          );
          resultSent = true;
          return;
        }

        stream.sendResult({
          ...finalTwist,
          permissions: result.permissions,
        });
        resultSent = true;
      } catch (error) {
        const logger = createLogger();
        logger.error("Error deploying twist", error as Error, {
          twist_admin_id: twistAdminId,
          environment,
          twist_name: name
        });
        // Send user-friendly error message
        const errorMessage =
          error instanceof Error
            ? error.message
            : "An unexpected error occurred during deployment";
        stream.sendError(errorMessage);
        resultSent = true;
      } finally {
        // Safeguard: ensure we always send a response
        if (!resultSent) {
          const logger = createLogger();
          logger.error("Deployment completed without sending result or error", new Error("No result sent"), {
            twist_admin_id: twistAdminId,
            environment
          });
          stream.sendError(
            "Deployment failed: No response generated. Please check server logs."
          );
        }
        stream.close();
      }
    })();

    // Keep the worker alive until deployment completes
    (c.executionCtx as ExecutionContext).waitUntil(deploymentPromise);

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
        userName: user?.user_metadata?.name || user?.user_metadata?.full_name || user?.email?.split("@")[0],
        userEmail: user?.email,
        dryRun,
      });
    } catch (error) {
      const logger = createLogger();
      logger.error("Error deploying twist", error as Error, {
        twist_admin_id: twistAdminId,
        environment,
        twist_name: name
      });
      // Send user-friendly error message
      const errorMessage =
        error instanceof Error
          ? error.message
          : "An unexpected error occurred during deployment";
      return new Response(`Deployment failed: ${errorMessage}`, {
        status: 500,
      });
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
      const logger = createLogger();
      logger.error("Error fetching deployed twist", finalError as Error, {
        twist_admin_id: twistAdminId,
        environment
      });
      return new Response(
        "Deployment succeeded, but failed to retrieve twist details. Please try refreshing.",
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
