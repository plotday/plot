import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { ItemSchema } from "../types";
import { handleValidationError } from "../utils/validation";

const database = new Hono<{ Bindings: Bindings }>();

// Schemas
const ToolSchema: z.ZodType<{
  id: string;
  tools?: { id: string; tools?: any }[];
}> = z.lazy(() =>
  z.object({
    id: z.string(),
    tools: z.array(ToolSchema).optional(),
  })
);

const DatabaseUpdateRequestSchema = z.object({
  type: z.enum(["activity", "priority", "session", "note", "priority_twist"]),
  event: z.enum(["created", "updated", "deleted"]),
  item: ItemSchema,
  previous: ItemSchema.optional(),
  twists: z.array(
    z.object({
      id: z.string(),
      environment: z.enum(["personal", "private", "review", "public"]),
      version: z.string(),
      priority_twist_id: z.string(),
      config: z.record(z.string(), z.any()).optional(),
    })
  ),
  users: z
    .array(
      z.object({
        user_id: z.string(),
      })
    )
    .optional(),
  timestamp: z.number().optional(),
});

export type DatabaseUpdateRequest = z.infer<typeof DatabaseUpdateRequestSchema>;

// POST /update - Database update webhook
database.post("/update", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DatabaseUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;

  // Add message to the updates queue for processing
  await c.env.UPDATES_QUEUE.send({
    type: body.type,
    event: body.event,
    item: body.item,
    previous: body.previous,
    twists: body.twists,
    users: body.users,
    timestamp: body.timestamp,
  });

  return c.json({ success: true });
});

export default database;
