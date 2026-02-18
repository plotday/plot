/**
 * Tracker identification middleware for API worker.
 *
 * Sets the authenticated user's distinctId on the request-scoped tracker
 * so that all PostHog events and exceptions captured during the request
 * are attributed to the correct user.
 */

import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";

/**
 * Tracker identification middleware.
 *
 * - Sets the authenticated user's ID as the tracker's distinctId
 * - No $identify events are sent — the Flutter app handles person profiles
 *
 * Should be applied after auth middleware in the middleware chain.
 */
export const trackerIdentifyMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const user = c.var.user;

  if (user) {
    c.var.tracker.setDistinctId(user.id);
  }

  await next();
};
