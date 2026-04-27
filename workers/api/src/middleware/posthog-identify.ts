/**
 * Tracker identification middleware for API worker.
 *
 * Sets the authenticated user's distinctId on the request-scoped tracker
 * so that all PostHog events and exceptions captured during the request
 * are attributed to the correct user. Person properties (email, name) are
 * set elsewhere — the Flutter app identifies on login — so this middleware
 * deliberately does not push them on every request.
 */

import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";

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
