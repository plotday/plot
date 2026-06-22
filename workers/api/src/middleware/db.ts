import type { MiddlewareHandler } from "hono";

import { createFrontendDb } from "../db";
import type { Bindings } from "../env";

/**
 * Creates a request-scoped Kysely instance, sets it on the context,
 * and guarantees cleanup after the handler completes.
 */
export const dbMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const db = createFrontendDb(c.env);
  c.set("db", db);
  try {
    await next();
  } finally {
    await db.destroy();
  }
};
