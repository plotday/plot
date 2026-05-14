import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { createDb } from "../db";
import { deployTwist } from "../twist/deployment";
import {
  createPublisher,
  getAccessiblePublishers,
} from "../twist/priority-management";
import { SSEStream, acceptsSSE } from "../utils/sse";
import { handleValidationError } from "../utils/validation";
import { createLogger } from "@plotday/worker-util";
import { deploymentRateLimiter } from "../middleware/rate-limit";
import { getEffectivePlan } from "../utils/plan";

declare const ENV: string;

const twist = new Hono<{ Bindings: Bindings }>();

const MAX_MODULE_SIZE = 10 * 1024 * 1024; // 10 MB in bytes
const MAX_SOURCEMAP_SIZE = 20 * 1024 * 1024; // 20 MB in bytes

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
      user.name ||
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
      .max(MAX_SOURCEMAP_SIZE, "Sourcemap size exceeds 20 MB limit")
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
    logoUrl: z.string().url().optional(),
    logoUrlDark: z.string().url().optional(),
    publisherId: z.coerce.number().optional(),
    environment: z
      .enum(["personal", "private", "review", "public"])
      .optional()
      .default("personal"),
    // Set by clients (e.g. the Twist Builder UI) when the twist source was
    // produced by `/twist/generate` rather than hand-written. Used only for
    // PostHog analytics.
    generatedFromSpec: z.boolean().optional().default(false),
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
  const publisherToken = c.var.publisherToken;
  const publisher = c.var.publisher;

  // Publisher tokens are scoped to a single publisher — return just that one
  // so the CLI's deploy flow can resolve the target publisher without needing
  // the user-level access that lists all accessible publishers.
  if (publisherToken && publisher) {
    return c.json([publisher]);
  }

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  const db = c.var.db;

  try {
    const publishers = await getAccessiblePublishers(user.id, db);
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

  const db = c.var.db;

  try {
    const publisher = await createPublisher(name, url || null, user.id, db);
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

  // Plan check: twist builder requires Pro or Team
  if (userToken && c.var.user && c.var.db) {
    const { plan } = await getEffectivePlan(c.var.db, c.var.user.id);
    if (plan !== "pro" && plan !== "team") {
      return c.json(
        { error: "Twist builder requires a Pro or Team plan" },
        403
      );
    }
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
            userId: c.var.user?.id ?? null,
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
      const source = await generateTwist({
        spec,
        env: c.env,
        userId: c.var.user?.id ?? null,
      });
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
// Returns publisher info for any non-personal deployment of this package.
// Returns 404 if the package has no non-personal twist rows.
twist.get("/twist/:id", async (c) => {
  const twistPackageId = c.req.param("id");
  const userToken = c.var.userToken;
  const publisherToken = c.var.publisherToken;

  if (!userToken && !publisherToken) {
    return new Response("Unauthorized", { status: 401 });
  }

  const db = c.var.db;

  const twistRow = await db
    .selectFrom("twist")
    .leftJoin("publisher", "publisher.id", "twist.publisher_id")
    .select([
      "twist.twist_package_id",
      "twist.created_at",
      "twist.updated_at",
      "publisher.id as publisher_id",
      "publisher.name as publisher_name",
      "publisher.email as publisher_email",
      "publisher.url as publisher_url",
    ])
    .where("twist.twist_package_id", "=", twistPackageId)
    .where("twist.environment", "!=", "personal")
    .orderBy("twist.created_at", "asc")
    .executeTakeFirst();

  if (!twistRow) {
    return new Response("Twist not published", { status: 404 });
  }

  return c.json({
    twist_package_id: twistRow.twist_package_id,
    publisher: twistRow.publisher_id
      ? {
          id: Number(twistRow.publisher_id),
          name: twistRow.publisher_name,
          email: twistRow.publisher_email,
          url: twistRow.publisher_url,
        }
      : null,
    created_at: twistRow.created_at,
    updated_at: twistRow.updated_at,
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
    logoUrl,
    logoUrlDark,
    publisherId,
    environment,
    generatedFromSpec,
  } = parseResult.data;

  const db = c.var.db;

  // Validate name is provided
  if (!name) {
    return new Response("Bad request: name is required", { status: 400 });
  }

  if (!urlPackageId) {
    return new Response("Bad request: twist package ID required", {
      status: 400,
    });
  }
  const packageId: string = urlPackageId;

  let userId: string | null = null;
  let resolvedPublisherId: number | null = null;

  if (environment === "personal") {
    // Personal environment: require user token.
    if (!userToken || !user) {
      return new Response(
        "Unauthorized: user token required for personal environment",
        { status: 401 }
      );
    }
    userId = user.id;
  } else {
    // Non-personal environment: description required.
    if (!description) {
      return new Response(
        "Bad request: description is required for non-personal deployments",
        { status: 400 }
      );
    }

    // Direct deploys to "public" are a dev-only shortcut for @plot.day users.
    // In production, public must be reached via the review → auto-approve flow.
    if (environment === "public") {
      const isDevelopment = typeof ENV !== "undefined" && ENV === "development";
      if (!isDevelopment) {
        return new Response(
          "Forbidden: direct public deploys are only allowed in development",
          { status: 403 }
        );
      }
      if (!userToken || !user) {
        return new Response(
          "Unauthorized: user token required for public deploys",
          { status: 401 }
        );
      }
      const email = user.email?.toLowerCase() ?? "";
      if (!email.endsWith("@plot.day")) {
        return new Response(
          "Forbidden: only @plot.day users can deploy directly to public",
          { status: 403 }
        );
      }
    }

    // Determine the publisher that owns this package. If any non-personal
    // twist row already exists for this package, its publisher_id pins the
    // publisher for this deploy.
    const existing = await db
      .selectFrom("twist")
      .select(["publisher_id"])
      .where("twist_package_id", "=", packageId)
      .where("environment", "!=", "personal")
      .where("publisher_id", "is not", null)
      .limit(1)
      .executeTakeFirst();

    const pinnedPublisherId =
      existing?.publisher_id !== undefined && existing?.publisher_id !== null
        ? Number(existing.publisher_id)
        : null;

    if (userToken && user) {
      let targetPublisherId: number;
      if (pinnedPublisherId !== null) {
        targetPublisherId = pinnedPublisherId;
      } else {
        if (publisherId === undefined) {
          return new Response(
            "Publisher ID is required for non-personal deployments",
            { status: 400 }
          );
        }
        targetPublisherId = Number(publisherId);
      }

      // Verify the user is a member of the publisher's auto-maintained group.
      const hasAccess = await db
        .selectFrom("group as g")
        .innerJoin("group_member as gm", "gm.group_id", "g.id")
        .innerJoin("user_contact as uc", "uc.contact_id", "gm.contact_id")
        .select("g.id")
        .where("g.auto_publisher_id", "=", targetPublisherId as any)
        .where("g.auto_maintained", "=", true)
        .where("uc.user_id", "=", user.id)
        .where("uc.linked", "=", true)
        .where("uc.archived_at", "is", null)
        .executeTakeFirst();

      if (!hasAccess) {
        return new Response(
          "Forbidden: you do not have access to this publisher",
          { status: 403 }
        );
      }

      resolvedPublisherId = targetPublisherId;
    } else if (publisherToken && publisher) {
      if (pinnedPublisherId !== null && publisher.id !== pinnedPublisherId) {
        return new Response(
          "Forbidden: publisher token does not match twist publisher",
          { status: 403 }
        );
      }
      resolvedPublisherId = publisher.id;
    } else {
      return new Response("Unauthorized", { status: 401 });
    }
  }

  // Check if client wants streaming response
  const useSSE = acceptsSSE(c.req.raw);

  if (useSSE) {
    // Stream progress updates via SSE
    const stream = new SSEStream();

    // Create a separate DB connection for the background deployment.
    // The middleware-scoped `db` will be destroyed when the handler returns
    // the streaming response, but deployment continues via waitUntil.
    const sseDb = createDb(c.env);

    // Start deployment in the background
    const deploymentPromise = (async () => {
      let resultSent = false;
      try {
        const result = await deployTwist({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          db: sseDb,
          twistPackageId: packageId,
          publisherId: resolvedPublisherId,
          userId,
          input:
            module !== undefined ? { module, sourcemap } : { source: source! },
          environment,
          name: name!,
          description,
          logoUrl,
          logoUrlDark,
          userName: user?.name || user?.email?.split("@")[0],
          userEmail: user?.email,
          dryRun,
          onProgress: (message) => stream.sendProgress(message),
          source: generatedFromSpec ? "spec" : "code",
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
        try {
          let finalQuery = sseDb
            .selectFrom("twist")
            .selectAll()
            .where("twist_package_id", "=", packageId)
            .where("environment", "=", environment);
          if (environment === "personal") {
            finalQuery = finalQuery.where("user_id", "=", userId);
          }
          const finalTwist = await finalQuery.executeTakeFirstOrThrow();

          stream.sendResult({
            ...finalTwist,
            permissions: result.permissions,
          });
          resultSent = true;
        } catch (fetchError) {
          const logger = createLogger();
          logger.error("Error fetching deployed twist", fetchError as Error, {
            twist_package_id: packageId,
            environment
          });
          stream.sendError(
            "Deployment succeeded, but failed to retrieve twist details. Please try refreshing."
          );
          resultSent = true;
        }
      } catch (error) {
        const logger = createLogger();
        // Translate the publisher-consistency trigger violation into a 403-style
        // message for the user.
        const translated = translateCheckViolation(error);
        if (translated) {
          stream.sendError(translated);
          resultSent = true;
          return;
        }
        logger.error("Error deploying twist", error as Error, {
          twist_package_id: packageId,
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
            twist_package_id: packageId,
            environment
          });
          stream.sendError(
            "Deployment failed: No response generated. Please check server logs."
          );
        }
        stream.close();
        await sseDb.destroy();
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
        db,
        twistPackageId: packageId,
        publisherId: resolvedPublisherId,
        userId,
        input:
          module !== undefined ? { module, sourcemap } : { source: source! },
        environment,
        name: name!,
        description,
        logoUrl,
        logoUrlDark,
        userName: user?.name || user?.email?.split("@")[0],
        userEmail: user?.email,
        dryRun,
        source: generatedFromSpec ? "spec" : "code",
      });
    } catch (error) {
      const translated = translateCheckViolation(error);
      if (translated) {
        return new Response(translated, { status: 403 });
      }
      const logger = createLogger();
      logger.error("Error deploying twist", error as Error, {
        twist_package_id: packageId,
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
    try {
      let finalQuery = db
        .selectFrom("twist")
        .selectAll()
        .where("twist_package_id", "=", packageId)
        .where("environment", "=", environment);
      if (environment === "personal") {
        finalQuery = finalQuery.where("user_id", "=", userId);
      }
      const finalTwist = await finalQuery.executeTakeFirstOrThrow();

      return c.json({
        ...finalTwist,
        permissions: result.permissions,
      });
    } catch (error) {
      const logger = createLogger();
      logger.error("Error fetching deployed twist", error as Error, {
        twist_package_id: packageId,
        environment
      });
      return new Response(
        "Deployment succeeded, but failed to retrieve twist details. Please try refreshing.",
        {
          status: 500,
        }
      );
    }
  }
});

/**
 * Translates the enforce_twist_package_publisher_consistency trigger's
 * check_violation into a user-facing forbidden message. Returns null if
 * the error isn't a publisher mismatch.
 */
function translateCheckViolation(error: unknown): string | null {
  if (!(error instanceof Error)) return null;
  const msg = error.message ?? "";
  if (msg.includes("twist_package_id") && msg.includes("is already owned by publisher")) {
    return "Forbidden: this twist package is already owned by a different publisher.";
  }
  return null;
}

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

  const db = c.var.db;

  // For personal environment, verify twist exists and user owns it.
  // For other environments, verify user is a member of the publisher's topic.
  if (environment === "personal") {
    const twistRow = await db
      .selectFrom("twist")
      .select(["id"])
      .where("twist_package_id", "=", twistPackageId)
      .where("environment", "=", "personal")
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!twistRow) {
      return new Response("Twist not found", { status: 404 });
    }
  } else {
    const twistRow = await db
      .selectFrom("twist")
      .select(["publisher_id"])
      .where("twist_package_id", "=", twistPackageId)
      .where("environment", "!=", "personal")
      .where("publisher_id", "is not", null)
      .limit(1)
      .executeTakeFirst();

    if (!twistRow || twistRow.publisher_id === null) {
      return new Response("Twist not found", { status: 404 });
    }

    const hasAccess = await db
      .selectFrom("group as g")
      .innerJoin("group_member as gm", "gm.group_id", "g.id")
      .innerJoin("user_contact as uc", "uc.contact_id", "gm.contact_id")
      .select("g.id")
      .where("g.auto_publisher_id", "=", twistRow.publisher_id)
      .where("g.auto_maintained", "=", true)
      .where("uc.user_id", "=", user.id)
      .where("uc.linked", "=", true)
      .where("uc.archived_at", "is", null)
      .executeTakeFirst();

    if (!hasAccess) {
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
