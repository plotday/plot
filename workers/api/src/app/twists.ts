import { Hono } from "hono";
import { z } from "zod";

import { twistFactory } from "../twist";
import {
  add as addTwist,
  archiveAndDeleteTwist,
  deleteTwist,
  getById as getTwistById,
  getByPriority as getTwistsByPriority,
  getAll as getAllTwists,
  update as updateTwist,
} from "../twist/management";
import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";

const twists = new Hono<{ Bindings: Bindings }>();

// Schemas
const TwistRequestSchema = z.object({
  priorityId: z.string(),
  twistId: z.string(),
  twistEnvironment: z
    .enum(["personal", "private", "review"])
    .optional()
    .default("personal"),
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
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }

  const twists = await getAllTwists(c.var.supabase, priorityId);
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
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }
  const twists = await getTwistsByPriority(c.var.supabase, priorityId);
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
    return c.json(dbPriorityTwist.id);
  } catch (error) {
    console.error("Error adding twist:", error);
    if (error instanceof Error) {
      console.warn(error.stack);
      return new Response(`Error adding twist: ${error.message}`, {
        status: 400,
      });
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
      return new Response(`Error updating twist: ${error.message}`, {
        status: 400,
      });
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
  await archiveAndDeleteTwist(c.var.supabase, twistId);
  return c.json({ success: true });
});

export default twists;
