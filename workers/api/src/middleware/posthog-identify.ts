/**
 * Tracker identification middleware for API worker.
 *
 * Sets the authenticated user's distinctId on the request-scoped tracker
 * so that all PostHog events and exceptions captured during the request
 * are attributed to the correct user, and pushes person properties so
 * users who never open the Flutter app (e.g. web-only signups) still get
 * a populated profile in PostHog.
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
    c.var.tracker.setPersonProperties(user.id, {
      email: user.email,
      name: user.name,
    });
  }

  await next();
};
