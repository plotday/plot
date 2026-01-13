import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { ItemSchema } from "../types";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
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

const DatabaseUpdateItemSchema = z.object({
  type: z.enum([
    "activity",
    "priority",
    "session",
    "note",
    "priority_twist",
    "activity_read",
    "priority_contact",
  ]),
  event: z.enum(["created", "updated", "deleted"]),
  item: ItemSchema,
  previous: ItemSchema.optional(),
  twists: z.array(
    z.object({
      id: z.number(),
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

const DatabaseUpdateRequestSchema = z.array(DatabaseUpdateItemSchema);

export type DatabaseUpdateItem = z.infer<typeof DatabaseUpdateItemSchema>;
export type DatabaseUpdateRequest = z.infer<typeof DatabaseUpdateRequestSchema>;

// POST /update - Database update webhook
database.post("/update", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const rawBody = await c.req.json();
    const parseResult = DatabaseUpdateRequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      // Log validation error to PostHog
      c.var.postHog.captureException(
        new Error("Validation error in /sync/update"),
        undefined,
        {
          path: c.req.path,
          method: c.req.method,
          error_type: "validation",
          validation_issues: parseResult.error.issues.map((issue) => ({
            path: issue.path.join("."),
            message: issue.message,
            code: issue.code,
          })),
          is_array: Array.isArray(rawBody),
          item_count: Array.isArray(rawBody) ? rawBody.length : 0,
        }
      );
      return handleValidationError(parseResult.error, rawBody);
    }
    const items = parseResult.data;

    // Add each message to the updates queue for processing
    for (const item of items) {
      await c.env.UPDATES_QUEUE.send({
        type: item.type,
        event: item.event,
        item: item.item,
        previous: item.previous,
        twists: item.twists,
        users: item.users,
        timestamp: item.timestamp,
      });
    }

    return c.json({ success: true });
  } catch (error) {
    // Log any unexpected errors to PostHog
    logger.error("Error in /sync/update endpoint", error as Error);
    c.var.postHog.captureException(error as Error, undefined, {
      path: c.req.path,
      method: c.req.method,
      error_type: "unexpected",
    });

    return new Response(
      `Internal server error: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      { status: 500 }
    );
  }
});

export default database;
