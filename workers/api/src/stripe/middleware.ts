import type { MiddlewareHandler } from "hono";

import type { Bindings } from "../env";

/**
 * Middleware for Stripe endpoints
 * DB connection is provided by the top-level dbMiddleware.
 * Integration is handled via Stripe signature verification in the endpoint.
 */
export const stripeMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  _c,
  next
) => {
  await next();
};
