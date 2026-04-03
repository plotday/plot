import { Hono } from "hono";
import { z } from "zod";

import { sql } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist";
import {
  activateDraft,
  add as addTwist,
  archiveAndDeleteTwist,
  createDraft,
  deleteDraft,
  deleteTwist,
  getAll as getAllTwists,
  getById as getTwistById,
  getByPriority as getTwistsByPriority,
  update as updateTwist,
} from "../twist/management";
import { resolveOptions } from "../twist/tools/factory";
import type { OptionsSchema } from "@plotday/twister/options";
import { saveSecureOptions } from "../utils/secure-options";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { notifySync } from "./sync/notify";
import { PlanLimitError } from "../utils/limits";

const twists = new Hono<{ Bindings: Bindings }>();

// Schemas
const TwistRequestSchema = z.object({
  priorityId: z.string(),
  twistId: z.coerce.number(), // Accept string or number, coerce to number (twist.id is bigint)
  twistEnvironment: z
    .enum(["personal", "private", "review", "public"])
    .optional()
    .default("public"),
  name: z.string().optional(),
  config: z.record(z.string(), z.any()).optional(),
});

const TwistUpdateRequestSchema = z.object({
  name: z.string().optional(),
  config: z.record(z.string(), z.any()).optional(),
});

const DraftRequestSchema = z.object({
  twistId: z.coerce.number(),
  twistEnvironment: z
    .enum(["personal", "private", "review", "public"])
    .optional()
    .default("public"),
  name: z.string().optional(),
});

const ActivateDraftSchema = z.object({
  priorityId: z.string().optional(), // Optional for sources (account-level)
  name: z.string(),
  config: z.record(z.string(), z.any()).optional(),
  syncables: z
    .array(
      z.object({
        provider: z.string(),
        syncableId: z.string(),
        priorityId: z.string().optional(),
        createThreads: z.string().optional(),
        createThreadsByType: z.record(z.string(), z.enum(["all", "actionable", "manual"])).optional(),
      })
    )
    .optional(),
});

// GET /sources - List user's connected sources
twists.get("/sources", async (c) => {
  try {
    const userId = c.var.user.id;

    // Get all priority_twists where twist.is_source = true, for the current user
    const sources = await c.var.db
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .leftJoin("publisher", "publisher.id", "twist_admin.publisher_id")
      .select([
        "priority_twist.id",
        "priority_twist.priority_id",
        "priority_twist.twist_id",
        "priority_twist.name",
        "priority_twist.owner_id",
        "priority_twist.config",
        "priority_twist.archived_at",
        "priority_twist.created_at",
        "priority_twist.updated_at",
        "twist.is_source",
        "twist.environment as twist_environment",
        "twist.version",
        "twist.permissions",
        "twist.options",
        "twist.logo_url",
        "twist.logo_url_dark",
        "publisher.name as author_name",
        "publisher.email as author_email",
        "publisher.url as author_url",
      ])
      .where("twist.is_source", "=", true)
      .where("priority_twist.owner_id", "=", userId)
      .where("priority_twist.archived_at", "is", null)
      .execute();

    return c.json(sources);
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error fetching connectors", error as Error);
    if (error instanceof Error) {
      return c.json({ message: `Error fetching connectors: ${error.message}` }, 400);
    }
    throw error;
  }
});

// GET /sources/summary - List user's connected sources with account info and enabled channel counts
// Optimized for the Connections modal list view: returns everything needed in a single request
// instead of requiring N separate /twist/:id/integrations calls.
twists.get("/sources/summary", async (c) => {
  try {
    const userId = c.var.user.id;

    // Get all active source priority_twists for the current user
    const sources = await c.var.db
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .select([
        "priority_twist.id",
        "priority_twist.name",
        "priority_twist.config",
        "twist.logo_url",
        "twist.logo_url_dark",
      ])
      .where("twist.is_source", "=", true)
      .where("priority_twist.owner_id", "=", userId)
      .where("priority_twist.archived_at", "is", null)
      .execute();

    if (sources.length === 0) {
      return c.json([]);
    }

    const sourceIds = sources.map((s) => s.id);

    // Batch query: enabled channel counts per source
    const enabledCounts = await c.var.db
      .selectFrom("source_channel")
      .select(["priority_twist_id"])
      .select((eb) => eb.fn.countAll().as("enabled_count"))
      .where("priority_twist_id", "in", sourceIds)
      .where("enabled", "=", true)
      .groupBy("priority_twist_id")
      .execute();

    const countMap = new Map<string, number>();
    for (const row of enabledCounts) {
      countMap.set(row.priority_twist_id, Number(row.enabled_count));
    }

    // Batch query: first connected account per source (via priority_twist_connection + contact)
    const accounts = await c.var.db
      .selectFrom("priority_twist_connection as ptc")
      .innerJoin("contact as c", "c.id", "ptc.actor_id")
      .select([
        "ptc.priority_twist_id",
        "ptc.provider",
        "c.name as account_name",
        "c.email as account_email",
      ])
      .where("ptc.priority_twist_id", "in", sourceIds)
      .where("ptc.user_id", "=", userId)
      .execute();

    // Use the first account per source
    const accountMap = new Map<string, { provider: string; name: string | null; email: string | null }>();
    for (const row of accounts) {
      if (!accountMap.has(row.priority_twist_id)) {
        accountMap.set(row.priority_twist_id, {
          provider: row.provider,
          name: row.account_name,
          email: row.account_email,
        });
      }
    }

    const result = sources.map((source) => {
      const account = accountMap.get(source.id);
      // For no-provider connectors, fall back to _accountName stored in config
      let accountName = account?.name ?? null;
      if (!accountName && source.config) {
        try {
          const cfg = typeof source.config === "string"
            ? JSON.parse(source.config)
            : source.config;
          if (cfg?._accountName) accountName = cfg._accountName;
        } catch { /* ignore parse errors */ }
      }
      return {
        id: source.id,
        name: source.name,
        logo_url: source.logo_url,
        logo_url_dark: source.logo_url_dark,
        account_name: accountName,
        account_email: account?.email ?? null,
        provider: account?.provider ?? null,
        enabled_count: countMap.get(source.id) ?? 0,
      };
    });

    return c.json(result);
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error fetching source summaries", error as Error);
    if (error instanceof Error) {
      return c.json({ message: `Error fetching source summaries: ${error.message}` }, 400);
    }
    throw error;
  }
});

// GET /twists - List all twists accessible to user for a priority
twists.get("/twists", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return c.json({ message: "Bad request (missing priorityId)" }, 400);
  }

  const twists = await getAllTwists(c.var.db, c.var.user.id, priorityId);
  return c.json(twists);
});

// GET /twist/:id - Get twist by ID
twists.get("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  const twists = await getTwistById(c.var.db, twistId);
  return c.json(twists);
});

// GET /twist - Get twists by priority
twists.get("/twist", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return c.json({ message: "Bad request (missing priorityId)" }, 400);
  }
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  logger.debug("Fetching installed twists for priority", { priority_id: priorityId });
  const twists = await getTwistsByPriority(c.var.db, priorityId);
  logger.debug("Found installed twists", { priority_id: priorityId, count: twists.length });
  return c.json(twists);
});

// POST /twist - Add twist to priority
twists.post("/twist", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = TwistRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const dbPriorityTwist = await addTwist(
      c.var.db,
      c.var.user.id,
      body.priorityId,
      body.twistId,
      body.twistEnvironment,
      body.name,
      body.config,
      {
        twistFactory: twistFactory({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          db: c.var.db,
        }),
      }
    );

    notifySync(c, body.priorityId);

    return c.json({ id: dbPriorityTwist.id });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error adding twist", error as Error, {
      priority_id: body.priorityId,
      twist_id: String(body.twistId),
      twist_environment: body.twistEnvironment,
    });
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof Error) {
      return c.json({ message: `Error adding twist: ${error.message}` }, 400);
    }
    throw error;
  }
});

// POST /twist/draft - Create a draft twist (no priority)
twists.post("/twist/draft", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DraftRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const draft = await createDraft(
      c.var.db,
      c.var.user.id,
      body.twistId,
      body.twistEnvironment,
      body.name
    );
    return c.json({ id: draft.id });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error creating draft twist", error as Error);
    if (error instanceof Error) {
      return c.json({ message: `Error creating draft: ${error.message}` }, 400);
    }
    throw error;
  }
});

// POST /twist/draft/:id/activate - Activate a draft twist
twists.post("/twist/draft/:id/activate", async (c) => {
  const draftId = c.req.param("id");
  const rawBody = await c.req.json();
  const parseResult = ActivateDraftSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    await activateDraft(
      c.var.db,
      c.env,
      draftId,
      body.priorityId,
      body.name,
      body.config,
      body.syncables,
      {
        twistFactory: twistFactory({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          db: c.var.db,
        }),
      }
    );

    if (body.priorityId) {
      notifySync(c, body.priorityId);
    }

    return c.json({ success: true });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error activating draft twist", error as Error);
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof Error) {
      return c.json({ message: `Error activating draft: ${error.message}` }, 400);
    }
    throw error;
  }
});

// DELETE /twist/draft/:id - Delete a draft twist
twists.delete("/twist/draft/:id", async (c) => {
  const draftId = c.req.param("id");
  try {
    await deleteDraft(c.var.db, draftId);
    return c.json({ success: true });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error deleting draft twist", error as Error);
    if (error instanceof Error) {
      return c.json({ message: `Error deleting draft: ${error.message}` }, 400);
    }
    throw error;
  }
});

// PATCH /twist/:id - Update twist
twists.patch("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  const rawBody = await c.req.json();
  const parseResult = TwistUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    // Load old record before update (for onOptionsChanged dispatch)
    let oldConfig: Record<string, unknown> | undefined;
    if (body.config) {
      const oldRecord = await c.var.db
        .selectFrom("priority_twist")
        .innerJoin("twist", "twist.id", "priority_twist.twist_id")
        .select(["priority_twist.config", "priority_twist.priority_id", "priority_twist.twist_id", "twist.options", "twist.environment"])
        .where("priority_twist.id", "=", twistId)
        .where("priority_twist.archived_at", "is", null)
        .executeTakeFirst();
      if (oldRecord) {
        oldConfig = oldRecord.config
          ? (typeof oldRecord.config === "string" ? JSON.parse(oldRecord.config) : oldRecord.config as Record<string, unknown>)
          : {};
      }
    }

    // Process secure options before saving config
    let cleanedConfig = body.config;
    if (body.config && oldConfig) {
      const twistRecord0 = await c.var.db
        .selectFrom("priority_twist")
        .innerJoin("twist", "twist.id", "priority_twist.twist_id")
        .select(["twist.options"])
        .where("priority_twist.id", "=", twistId)
        .executeTakeFirst();

      if (twistRecord0?.options && c.env.AI_KEY_ENCRYPTION_KEY) {
        const optSchema = (typeof twistRecord0.options === "string"
          ? JSON.parse(twistRecord0.options)
          : twistRecord0.options) as OptionsSchema;

        cleanedConfig = await saveSecureOptions(
          c.var.db,
          c.env.AI_KEY_ENCRYPTION_KEY,
          twistId,
          optSchema,
          body.config
        );
      }
    }

    const dbTwist = await updateTwist(c.var.db, twistId, {
      ...body,
      config: cleanedConfig,
    });

    // Dispatch onOptionsChanged if config changed
    if (body.config && oldConfig) {
      const twistRecord = await c.var.db
        .selectFrom("priority_twist")
        .innerJoin("twist", "twist.id", "priority_twist.twist_id")
        .select(["priority_twist.priority_id", "priority_twist.twist_id", "twist.options", "twist.environment"])
        .where("priority_twist.id", "=", twistId)
        .executeTakeFirst();

      if (twistRecord?.options) {
        const schema = (typeof twistRecord.options === "string"
          ? JSON.parse(twistRecord.options)
          : twistRecord.options) as OptionsSchema;

        if (Object.keys(schema).length > 0) {
          const oldOptions = resolveOptions(schema, oldConfig);
          const newOptions = resolveOptions(schema, body.config);

          // Check if resolved options actually differ
          const changed = Object.keys(schema).some(
            (k) => oldOptions[k] !== newOptions[k]
          );

          if (changed) {
            try {
              const factory = twistFactory({
                env: c.env,
                ctx: c.executionCtx as ExecutionContext,
                db: c.var.db,
              });
              const twistInstance = await factory({
                id: String(twistRecord.twist_id),
                environment: twistRecord.environment as any,
                priorityId: twistRecord.priority_id!,
                priorityTwistId: twistId,
              });
              await twistInstance.callCallback([], "onOptionsChanged", oldOptions, newOptions);
            } catch (error) {
              const context = extractRequestContext(c);
              const logger = createLogger(context);
              logger.warn("Failed to dispatch onOptionsChanged", { error: String(error) });
            }
          }
        }
      }
    }

    return c.json(dbTwist);
  } catch (error) {
    if (error instanceof Error) {
      return c.json({ message: `Error updating twist: ${error.message}` }, 400);
    }
    throw error;
  }
});

// DELETE /twist/:id - Delete twist
twists.delete("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  await deleteTwist(c.var.db, twistId);
  return c.json({ success: true });
});

// GET /twist/:id/available-link-channels - List available source channels for link observation
twists.get("/twist/:id/available-link-channels", async (c) => {
  const priorityTwistId = c.req.param("id");
  const queryPriorityId = c.req.query("priorityId");
  try {
    let priorityId: string | null = queryPriorityId || null;

    if (!priorityId) {
      // Derive from the twist's priority_id (edit flow)
      const twist = await c.var.db
        .selectFrom("priority_twist")
        .select(["priority_id"])
        .where("id", "=", priorityTwistId)
        .where("archived_at", "is", null)
        .executeTakeFirst();

      if (!twist?.priority_id) {
        return c.json({ message: "Twist not found or not installed" }, 404);
      }
      priorityId = twist.priority_id;
    }

    // Get the selected priority's path for tree filtering
    const selectedPriority = await c.var.db
      .selectFrom("priority")
      .select(["path"])
      .where("id", "=", priorityId)
      .executeTakeFirst();

    if (!selectedPriority) {
      return c.json({ message: "Priority not found" }, 404);
    }

    const selectedPath = selectedPriority.path;

    // Find enabled source channels whose priority is the selected priority or a descendant
    const channels = await c.var.db
      .selectFrom("source_channel")
      .innerJoin("priority_twist", "priority_twist.id", "source_channel.priority_twist_id")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .leftJoin("priority as channel_priority", "channel_priority.id", "source_channel.priority_id")
      .innerJoin("user as source_owner", "source_owner.id", "priority_twist.owner_id")
      .select([
        "source_channel.channel_id",
        "source_channel.title",
        "source_channel.priority_twist_id as source_priority_twist_id",
        "priority_twist.name as source_name",
        "source_owner.email as account_name",
        "twist.logo_url",
        "twist.logo_url_dark",
      ])
      .where("source_channel.enabled", "=", true)
      .where("priority_twist.archived_at", "is", null)
      .where("priority_twist.id", "!=", priorityTwistId)
      .where(
        sql<boolean>`(channel_priority.path <@ ${selectedPath}::ltree)`
      )
      .execute();

    return c.json(channels);
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error fetching available link channels", error as Error);
    if (error instanceof Error) {
      return c.json({ message: error.message }, 400);
    }
    throw error;
  }
});

// GET /twist/:id/link-channels - List connected source channels for a twist
twists.get("/twist/:id/link-channels", async (c) => {
  const priorityTwistId = c.req.param("id");
  try {
    const channels = await c.var.db
      .selectFrom("priority_twist_channel")
      .innerJoin(
        "source_channel",
        (join) =>
          join
            .onRef("source_channel.priority_twist_id", "=", "priority_twist_channel.source_priority_twist_id")
            .onRef("source_channel.channel_id", "=", "priority_twist_channel.channel_id")
      )
      .innerJoin("priority_twist", "priority_twist.id", "priority_twist_channel.source_priority_twist_id")
      .innerJoin("user as source_owner", "source_owner.id", "priority_twist.owner_id")
      .select([
        "priority_twist_channel.id",
        "priority_twist_channel.source_priority_twist_id",
        "priority_twist_channel.channel_id",
        "priority_twist_channel.enabled",
        "source_channel.title",
        "priority_twist.name as source_name",
        "source_owner.email as account_name",
      ])
      .where("priority_twist_channel.priority_twist_id", "=", priorityTwistId)
      .execute();

    return c.json(channels);
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error fetching link channels", error as Error);
    if (error instanceof Error) {
      return c.json({ message: error.message }, 400);
    }
    throw error;
  }
});

// PUT /twist/:id/link-channels - Batch upsert connected source channels
twists.put("/twist/:id/link-channels", async (c) => {
  const priorityTwistId = c.req.param("id");
  const rawBody = await c.req.json();

  const schema = z.array(
    z.object({
      sourcePriorityTwistId: z.string().uuid(),
      channelId: z.string(),
      enabled: z.boolean(),
    })
  );
  const parseResult = schema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const channels = parseResult.data;

  try {
    // Verify the twist exists
    const twist = await c.var.db
      .selectFrom("priority_twist")
      .select(["id"])
      .where("id", "=", priorityTwistId)
      .where("archived_at", "is", null)
      .executeTakeFirst();

    if (!twist) {
      return c.json({ message: "Twist not found" }, 404);
    }

    // Upsert each channel connection
    for (const ch of channels) {
      await c.var.db
        .insertInto("priority_twist_channel")
        .values({
          priority_twist_id: priorityTwistId,
          source_priority_twist_id: ch.sourcePriorityTwistId,
          channel_id: ch.channelId,
          enabled: ch.enabled,
        })
        .onConflict((oc) =>
          oc
            .columns(["priority_twist_id", "source_priority_twist_id", "channel_id"])
            .doUpdateSet({ enabled: ch.enabled })
        )
        .execute();
    }

    return c.json({ success: true });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error updating link channels", error as Error);
    if (error instanceof Error) {
      return c.json({ message: error.message }, 400);
    }
    throw error;
  }
});

// DELETE /twist/:id/archive-activities - Archive activities and delete twist
twists.delete("/twist/:id/archive-activities", async (c) => {
  const twistId = c.req.param("id");
  const result = await archiveAndDeleteTwist(c.var.db, twistId);

  if (result?.priority_id) {
    notifySync(c, result.priority_id);
  }

  return c.json({ success: true });
});

export default twists;
