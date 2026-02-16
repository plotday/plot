import type { MiddlewareHandler } from "hono";

import { createDb } from "../db";
import type { Bindings } from "../env";

/**
 * Middleware for Stripe endpoints
 * Sets up database connection
 * Integration is handled via Stripe signature verification in the endpoint
 */
export const stripeMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  c.set("db", createDb(c.env));

  await next();
};
