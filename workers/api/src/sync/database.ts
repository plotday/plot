import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
import { disposeRpc } from "../utils/rpc";
import { handleValidationError } from "../utils/validation";

const database = new Hono<{ Bindings: Bindings }>();

// Schema for new batch sync endpoints
const UserSyncRequestSchema = z.object({
  ids: z.array(z.string().uuid()),
});

const TwistSyncRequestSchema = z.object({
  ids: z.array(z.string().uuid()),
});

// POST /users - Batch user sync notification
database.post("/users", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const rawBody = await c.req.json();
    const parseResult = UserSyncRequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      c.var.postHog.captureException(
        new Error("Validation error in /sync/users"),
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
        }
      );
      return handleValidationError(parseResult.error, rawBody);
    }
    const { ids } = parseResult.data;

    // Get or create UserSync DO for each user and call notify()
    for (const userId of ids) {
      const doId = c.env.USER_SYNC.idFromName(userId);
      const userSync = c.env.USER_SYNC.get(doId);
      const result = await userSync.fetch(
        new Request("http://do/notify", {
          method: "POST",
          body: JSON.stringify({ id: userId }),
        })
      );
      disposeRpc(result);
    }

    return c.json({ success: true, count: ids.length });
  } catch (error) {
    logger.error("Error in /sync/users endpoint", error as Error);
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

// POST /twists - Batch twist sync notification
database.post("/twists", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const rawBody = await c.req.json();
    const parseResult = TwistSyncRequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      c.var.postHog.captureException(
        new Error("Validation error in /sync/twists"),
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
        }
      );
      return handleValidationError(parseResult.error, rawBody);
    }
    const { ids } = parseResult.data;

    // Get or create TwistSync DO for each priority_twist and call notify()
    for (const priorityTwistId of ids) {
      const doId = c.env.TWIST_SYNC.idFromName(priorityTwistId);
      const twistSync = c.env.TWIST_SYNC.get(doId);
      const result = await twistSync.fetch(
        new Request("http://do/notify", {
          method: "POST",
          body: JSON.stringify({ id: priorityTwistId }),
        })
      );
      disposeRpc(result);
    }

    return c.json({ success: true, count: ids.length });
  } catch (error) {
    logger.error("Error in /sync/twists endpoint", error as Error);
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
