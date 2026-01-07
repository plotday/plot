import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { twistFactory } from "../twist";
import {
  add as addTwist,
  archiveAndDeleteTwist,
  deleteTwist,
  getAll as getAllTwists,
  getById as getTwistById,
  getByPriority as getTwistsByPriority,
  update as updateTwist,
} from "../twist/management";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
import { handleValidationError } from "../utils/validation";

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

// GET /twists - List all twists accessible to user for a priority
twists.get("/twists", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return c.json({ message: "Bad request (missing priorityId)" }, 400);
  }

  const twists = await getAllTwists(c.var.supabase, c.var.supabaseAdmin, priorityId);
  return c.json(twists);
});

// GET /twist/:id - Get twist by ID
twists.get("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  const twists = await getTwistById(c.var.supabase, twistId);
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
  const twists = await getTwistsByPriority(c.var.supabase, priorityId);
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
      c.var.supabase,
      c.var.supabaseAdmin,
      body.priorityId,
      body.twistId,
      body.twistEnvironment,
      body.name,
      body.config,
      {
        twistFactory: twistFactory({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          supabase: c.var.supabaseAdmin,
        }),
      }
    );
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
    const dbTwist = await updateTwist(c.var.supabase, twistId, body);
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
  await deleteTwist(c.var.supabase, twistId);
  return c.json({ success: true });
});

// DELETE /twist/:id/archive-activities - Archive activities and delete twist
twists.delete("/twist/:id/archive-activities", async (c) => {
  const twistId = c.req.param("id");
  const result = await archiveAndDeleteTwist(c.var.supabase, twistId);

  // Broadcast to all users with access to the priority
  if (result?.priority_id) {
    try {
      // Get users with access to this priority
      const usersResult = await c.var.supabase.rpc(
        "get_users_with_priority_access",
        {
          target_priority_id: result.priority_id,
        }
      );

      if (usersResult.data && usersResult.data.length > 0) {
        // Send broadcast to each user
        for (const user of usersResult.data) {
          try {
            const broadcastId = c.env.BROADCAST.idFromName(user.user_id);
            const broadcast = c.env.BROADCAST.get(broadcastId);
            await broadcast.send({
              type: "sync",
              table: "priority_twist",
            });
            // Also sync actor view since priority_twist is part of actor
            await broadcast.send({
              type: "sync",
              table: "actor",
            });
          } catch (broadcastError) {
            const logger = createLogger();
            logger.error("Error broadcasting to user", broadcastError as Error, {
              user_id: user.user_id,
              priority_id: result.priority_id,
            });
          }
        }
      }
    } catch (error) {
      const logger = createLogger();
      logger.error("Error broadcasting twist archive", error as Error, {
        priority_id: result.priority_id,
      });
      // Don't fail the request if broadcast fails
    }
  }

  return c.json({ success: true });
});

export default twists;
