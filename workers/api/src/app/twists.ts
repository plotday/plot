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
  getByPriority as getTwistsByPriority,
  update as updateTwist,
} from "../twist/management";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { notifySync } from "./sync/notify";

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
  priorityId: z.string(),
  name: z.string(),
  config: z.record(z.string(), z.any()).optional(),
  syncables: z
    .array(
      z.object({
        provider: z.string(),
        syncableId: z.string(),
      })
    )
    .optional(),
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

    notifySync(c, body.priorityId);

    return c.json({ success: true });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error activating draft twist", error as Error);
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
    const dbTwist = await updateTwist(c.var.db, twistId, body);
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
