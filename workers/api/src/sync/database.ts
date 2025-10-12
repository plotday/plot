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
  type: z.enum(["activity", "priority", "session"]),
  event: z.enum(["created", "updated", "deleted"]),
  item: ItemSchema,
  agents: z.array(
    z.object({
      id: z.string(),
      environment: z.string(),
      version: z.string(),
      priority_agent_id: z.string(),
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
  table: z.string().optional(),
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
    agents: body.agents,
    users: body.users,
    timestamp: body.timestamp,
    table: body.table,
  });

  return c.json({ success: true });
});

export default database;
