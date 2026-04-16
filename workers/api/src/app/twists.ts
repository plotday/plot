import { Hono } from "hono";
import { z } from "zod";

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
  getByFilter,
  update as updateTwist,
} from "../twist/management";
import { resolveOptions } from "../twist/tools/factory";
import type { OptionsSchema } from "@plotday/twister/options";
import { saveSecureOptions } from "../utils/secure-options";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { notifyUserSync } from "./sync/notify";
import { PlanLimitError, SingleInstanceError } from "../utils/limits";

const twists = new Hono<{ Bindings: Bindings }>();

// Schemas
const TwistRequestSchema = z.object({
  priorityId: z.string().optional(),
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
  teamId: z.string().nullable().optional(),
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
  teamId: z.string().nullable().optional(),
  syncables: z
    .array(
      z.object({
        provider: z.string(),
        syncableId: z.string(),
      })
    )
    .optional(),
});

// GET /sources - List user's connected sources
twists.get("/sources", async (c) => {
  try {
    const userId = c.var.user.id;

    // Get all twist_instances where twist.is_source = true, for the current user
    const sources = await c.var.db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .innerJoin("twist_admin", "twist_admin.id", "twist.twist_admin_id")
      .leftJoin("publisher", "publisher.id", "twist_admin.publisher_id")
      .select([
        "twist_instance.id",
        "twist_instance.twist_id",
        "twist_instance.name",
        "twist_instance.owner_id",
        "twist_instance.options",
        "twist_instance.archived_at",
        "twist_instance.created_at",
        "twist_instance.updated_at",
        "twist.is_source",
        "twist.environment as twist_environment",
        "twist.version",
        "twist.permissions",
        "twist.options_schema",
        "twist.logo_url",
        "twist.logo_url_dark",
        "publisher.name as author_name",
        "publisher.email as author_email",
        "publisher.url as author_url",
      ])
      .where("twist.is_source", "=", true)
      .where("twist_instance.owner_id", "=", userId)
      .where("twist_instance.archived_at", "is", null)
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

    // Get all active source twist_instances for the current user
    const sources = await c.var.db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select([
        "twist_instance.id",
        "twist_instance.name",
        "twist_instance.options",
        "twist.logo_url",
        "twist.logo_url_dark",
      ])
      .where("twist.is_source", "=", true)
      .where("twist_instance.owner_id", "=", userId)
      .where("twist_instance.archived_at", "is", null)
      .execute();

    if (sources.length === 0) {
      return c.json([]);
    }

    const sourceIds = sources.map((s) => s.id);

    // Batch query: enabled channel counts per source
    const enabledCounts = await c.var.db
      .selectFrom("channel")
      .select(["twist_instance_id"])
      .select((eb) => eb.fn.countAll().as("enabled_count"))
      .where("twist_instance_id", "in", sourceIds)
      .where("enabled", "=", true)
      .groupBy("twist_instance_id")
      .execute();

    const countMap = new Map<string, number>();
    for (const row of enabledCounts) {
      countMap.set(row.twist_instance_id, Number(row.enabled_count));
    }

    // Batch query: first connected account per source (via twist_instance_connection + contact)
    const accounts = await c.var.db
      .selectFrom("twist_instance_connection as ptc")
      .innerJoin("contact as c", "c.id", "ptc.actor_id")
      .select([
        "ptc.twist_instance_id",
        "ptc.provider",
        "c.name as account_name",
        "c.email as account_email",
      ])
      .where("ptc.twist_instance_id", "in", sourceIds)
      .where("ptc.user_id", "=", userId)
      .execute();

    // Use the first account per source
    const accountMap = new Map<string, { provider: string; name: string | null; email: string | null }>();
    for (const row of accounts) {
      if (!accountMap.has(row.twist_instance_id)) {
        accountMap.set(row.twist_instance_id, {
          provider: row.provider,
          name: row.account_name,
          email: row.account_email,
        });
      }
    }

    const result = sources.map((source) => {
      const account = accountMap.get(source.id);
      // For no-provider connectors, fall back to _accountName stored in options
      let accountName = account?.name ?? null;
      if (!accountName && source.options) {
        try {
          const cfg = typeof source.options === "string"
            ? JSON.parse(source.options)
            : source.options;
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

// GET /twists - List all twists accessible to user
twists.get("/twists", async (c) => {
  const twists = await getAllTwists(c.var.db, c.var.user.id);
  return c.json(twists);
});

// GET /twist/:id - Get twist by ID
twists.get("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  const twists = await getTwistById(c.var.db, twistId);
  return c.json(twists);
});

// GET /twist - Get twists, optionally filtered by teamId
twists.get("/twist", async (c) => {
  const teamId = c.req.query("teamId");
  if (teamId) {
    // Verify user is a member of the team
    const membership = await c.var.db
      .selectFrom("team_user")
      .select("user_id")
      .where("team_id", "=", teamId)
      .where("user_id", "=", c.var.user.id)
      .executeTakeFirst();
    if (!membership) {
      return c.json({ message: "Forbidden: you are not a member of this team" }, 403);
    }
  }
  const twists = await getByFilter(c.var.db, c.var.user.id, teamId);
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
    const dbTwistInstance = await addTwist(
      c.var.db,
      c.var.user.id,
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

    notifyUserSync(c, c.var.user.id);

    return c.json({ id: dbTwistInstance.id });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error adding twist", error as Error, {
      twist_id: String(body.twistId),
      twist_environment: body.twistEnvironment,
    });
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof SingleInstanceError) {
      return c.json(error.toJSON(), 409);
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
      },
      body.teamId
    );

    notifyUserSync(c, c.var.user.id);

    return c.json({ success: true });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error activating draft twist", error as Error);
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof SingleInstanceError) {
      return c.json(error.toJSON(), 409);
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
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select(["twist_instance.options", "twist_instance.twist_id", "twist.options_schema", "twist.environment"])
        .where("twist_instance.id", "=", twistId)
        .where("twist_instance.archived_at", "is", null)
        .executeTakeFirst();
      if (oldRecord) {
        oldConfig = oldRecord.options
          ? (typeof oldRecord.options === "string" ? JSON.parse(oldRecord.options) : oldRecord.options as Record<string, unknown>)
          : {};
      }
    }

    // Process secure options before saving config
    let cleanedConfig = body.config;
    if (body.config && oldConfig) {
      const twistRecord0 = await c.var.db
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select(["twist.options_schema"])
        .where("twist_instance.id", "=", twistId)
        .executeTakeFirst();

      if (twistRecord0?.options_schema && c.env.AI_KEY_ENCRYPTION_KEY) {
        const optSchema = (typeof twistRecord0.options_schema === "string"
          ? JSON.parse(twistRecord0.options_schema)
          : twistRecord0.options_schema) as OptionsSchema;

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
        .selectFrom("twist_instance")
        .innerJoin("twist", "twist.id", "twist_instance.twist_id")
        .select(["twist_instance.twist_id", "twist.options_schema", "twist.environment"])
        .where("twist_instance.id", "=", twistId)
        .executeTakeFirst();

      if (twistRecord?.options_schema) {
        const schema = (typeof twistRecord.options_schema === "string"
          ? JSON.parse(twistRecord.options_schema)
          : twistRecord.options_schema) as OptionsSchema;

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
                twistInstanceId: twistId,
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
  await c.var.db.transaction().execute(async (trx) => {
    await deleteTwist(trx, twistId);
  });
  return c.json({ success: true });
});

// GET /twist/:id/available-link-channels - List enabled channels from the same
// user that this twist could observe.
twists.get("/twist/:id/available-link-channels", async (c) => {
  const twistInstanceId = c.req.param("id");
  try {
    // Resolve the twist's owner so we only show channels from the same user
    const twist = await c.var.db
      .selectFrom("twist_instance")
      .select(["owner_id"])
      .where("id", "=", twistInstanceId)
      .where("archived_at", "is", null)
      .executeTakeFirst();

    if (!twist) {
      return c.json({ message: "Twist not found" }, 404);
    }

    const channels = await c.var.db
      .selectFrom("channel")
      .innerJoin("twist_instance", "twist_instance.id", "channel.twist_instance_id")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .innerJoin("user as source_owner", "source_owner.id", "twist_instance.owner_id")
      .select([
        "channel.channel_id",
        "channel.title",
        "channel.twist_instance_id as source_twist_instance_id",
        "twist_instance.name as source_name",
        "source_owner.email as account_name",
        "twist.logo_url",
        "twist.logo_url_dark",
      ])
      .where("channel.enabled", "=", true)
      .where("twist_instance.archived_at", "is", null)
      .where("twist_instance.id", "!=", twistInstanceId)
      .where("twist_instance.owner_id", "=", twist.owner_id)
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
  const twistInstanceId = c.req.param("id");
  try {
    const channels = await c.var.db
      .selectFrom("twist_instance_channel")
      .innerJoin(
        "channel",
        (join) =>
          join
            .onRef("channel.twist_instance_id", "=", "twist_instance_channel.source_twist_instance_id")
            .onRef("channel.channel_id", "=", "twist_instance_channel.channel_id")
      )
      .innerJoin("twist_instance", "twist_instance.id", "twist_instance_channel.source_twist_instance_id")
      .innerJoin("user as source_owner", "source_owner.id", "twist_instance.owner_id")
      .select([
        "twist_instance_channel.id",
        "twist_instance_channel.source_twist_instance_id",
        "twist_instance_channel.channel_id",
        "twist_instance_channel.enabled",
        "channel.title",
        "twist_instance.name as source_name",
        "source_owner.email as account_name",
      ])
      .where("twist_instance_channel.twist_instance_id", "=", twistInstanceId)
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
  const twistInstanceId = c.req.param("id");
  const rawBody = await c.req.json();

  const schema = z.array(
    z.object({
      sourceTwistInstanceId: z.string().uuid(),
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
      .selectFrom("twist_instance")
      .select(["id"])
      .where("id", "=", twistInstanceId)
      .where("archived_at", "is", null)
      .executeTakeFirst();

    if (!twist) {
      return c.json({ message: "Twist not found" }, 404);
    }

    // Upsert each channel connection
    for (const ch of channels) {
      await c.var.db
        .insertInto("twist_instance_channel")
        .values({
          twist_instance_id: twistInstanceId,
          source_twist_instance_id: ch.sourceTwistInstanceId,
          channel_id: ch.channelId,
          enabled: ch.enabled,
        })
        .onConflict((oc) =>
          oc
            .columns(["twist_instance_id", "source_twist_instance_id", "channel_id"])
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

  if (result?.owner_id) {
    notifyUserSync(c, result.owner_id);
  }

  return c.json({ success: true });
});

export default twists;
