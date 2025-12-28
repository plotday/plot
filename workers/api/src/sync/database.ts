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
  type: z.enum(["activity", "priority", "session", "note", "priority_twist", "activity_read"]),
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

export type DatabaseUpdateRequest = z.infer<typeof DatabaseUpdateRequestSchema>;

// POST /update - Database update webhook
database.post("/update", async (c) => {
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
          validation_issues: parseResult.error.issues.map(issue => ({
            path: issue.path.join("."),
            message: issue.message,
            code: issue.code,
          })),
          item_type: rawBody?.type,
          event: rawBody?.event,
          has_item: !!rawBody?.item,
          has_previous: !!rawBody?.previous,
        }
      );
      return handleValidationError(parseResult.error, rawBody);
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
  } catch (error) {
    // Log any unexpected errors to PostHog
    console.error("Error in /sync/update endpoint:", error);
    c.var.postHog.captureException(error as Error, undefined, {
      path: c.req.path,
      method: c.req.method,
      error_type: "unexpected",
    });

    return new Response(
      `Internal server error: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

export default database;
