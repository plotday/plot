/**
 * PostHog identification middleware for API worker.
 *
 * Identifies the authenticated user with PostHog, setting their email and name
 * as person properties. This creates person profiles in PostHog for analytics.
 */

import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";

/**
 * PostHog identification middleware.
 *
 * - Identifies the authenticated user with PostHog if present
 * - Sets email and name as person properties
 * - Sets signed_up_time as a once-only property
 *
 * Should be applied after auth middleware in the middleware chain.
 */
export const postHogIdentifyMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const user = c.var.user;

  if (user) {
    const clientInfo = c.var.clientInfo;
    c.var.postHog.identify({
      distinctId: user.id,
      properties: {
        $set: {
          email: user.email,
          name: user.name,
          ...(clientInfo
            ? {
                app_version: clientInfo.version,
                app_build: clientInfo.buildNumber,
                app_platform: clientInfo.platform,
              }
            : {}),
        },
      },
    });
  }

  await next();
};
