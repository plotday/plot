import { Container } from "@cloudflare/containers";
import { Hono } from "hono";
import { PostHog } from "posthog-node";

import { Tracker } from "./utils/tracker";
import account from "./app/account";
import device from "./app/device";
import invitation from "./app/invitation";
import share from "./app/share";
import twists from "./app/twists";
import twistIntegrations from "./app/twist-integrations";
// Import app routes and middleware
import { authMiddleware as appAuthMiddleware } from "./app/auth";
import authRoutes from "./app/authRoutes";
import callbacks from "./app/callbacks";
import { corsMiddleware as appCorsMiddleware } from "./app/cors";
import files from "./app/files";
import appSync from "./app/sync";
import summary from "./app/summary";
import updates from "./app/updates";
import type { Bindings } from "./env";
import { clientVersionMiddleware } from "./middleware/client-version";
import { trackerIdentifyMiddleware } from "./middleware/posthog-identify";
import { requestIdMiddleware } from "./middleware/request-id";
import { queue } from "./queue";
import twist from "./sdk/twist";
// Import SDK routes and middleware
import { authMiddleware as sdkAuthMiddleware } from "./sdk/auth";
import priority from "./sdk/priority";
import tokens from "./sdk/tokens";
// Import Stripe routes and middleware
import { stripeMiddleware } from "./stripe/middleware";
import stripe from "./stripe/stripe";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext, extractErrorContext, mergeContext } from "./utils/log-context";
// Import webhook routes
import webhook from "./webhook";
// Import rate limiting middleware
import { generalRateLimiter, appSyncRateLimiter } from "./middleware/rate-limit";

// Export Durable Objects
export { Storage } from "./state/storage";
export { CallbacksState } from "./state/callbacks";
export { Broadcast } from "./state/broadcast";
export { Usage } from "./state/usage";
export { LogSubscriptions } from "./state/log-subscriptions";
export { HttpProxy } from "./twist/http-proxy";
export { LogStream } from "./state/log-stream";
export { SdkTokenStore } from "./state/sdk-token-store";
export { TwistTail } from "./twist/tail";
export { UserSync } from "./state/user-sync";
export { TwistSync } from "./state/twist-sync";
export { SyncNotify } from "./state/sync-notify";
export { SyncRecovery } from "./state/sync-recovery";
export { PrivacyReporting } from "./state/privacy-reporting";

export class TwistBuilder extends Container {
  defaultPort = 3000;
  sleepAfter = "60m";
}

// Create main app
const app = new Hono<{ Bindings: Bindings }>();

// Apply request ID middleware first (for trace correlation)
app.use("*", requestIdMiddleware);
app.use("*", clientVersionMiddleware);

// Create request-scoped tracker (wraps PostHog with optional distinctId)
app.use("*", async (c, next) => {
  const postHog = new PostHog(c.env.POSTHOG_API_KEY, {
    host: c.env.POSTHOG_HOST,
    flushAt: 5,
    flushInterval: 10,
  });
  c.set("tracker", new Tracker(postHog));
  try {
    await next();
  } finally {
    c.executionCtx.waitUntil(Promise.resolve(c.var.tracker.shutdown()));
  }
});

// Rate limiting is now applied per-section instead of globally
// This allows sync endpoints to be exempt from rate limiting

// Add error handler for PostHog error tracking and structured logging
app.onError(async (err, c) => {
  try {
    // Extract context from request and error
    const requestContext = extractRequestContext(c);
    const errorContext = extractErrorContext(err);
    const context = mergeContext(requestContext, errorContext);

    // Log error with structured context
    const logger = createLogger();
    logger.error("Unhandled error in request", err, context);

    // Capture in PostHog with same context
    c.var.tracker.captureException(err, {
      ...context,
      path: c.req.path,
      method: c.req.method,
      url: c.req.url,
    });
  } catch (e) {
    // Fallback to console if structured logging fails
    console.error("Error in error handler:", e);
    console.error("Original error:", err);
  }

  // Set CORS headers for error responses to prevent CORS errors in browser
  const origin = c.req.header("Origin");
  const allowedOrigins = [
    "http://localhost:8788",
    "https://preview.plot.day",
    "https://app.plot.day",
  ];

  if (origin && allowedOrigins.includes(origin)) {
    c.header("Access-Control-Allow-Origin", origin);
    c.header("Access-Control-Allow-Credentials", "true");
  }

  return c.json({ error: "Internal Server Error" }, 500);
});

// App section - endpoints called by the Flutter app
const appSection = new Hono<{ Bindings: Bindings }>();
appSection.use("*", async (c, next) => {
  // Sync endpoints use appSyncRateLimiter instead
  if (c.req.path.startsWith("/app/sync")) return next();
  return generalRateLimiter(c, next);
});
appSection.use(appCorsMiddleware);
appSection.use("*", appAuthMiddleware);
appSection.use("*", trackerIdentifyMiddleware);
appSection.route("/", account);
appSection.route("/", device);
appSection.route("/", invitation);
appSection.route("/", share);
appSection.route("/", twists);
appSection.route("/", twistIntegrations);
appSection.route("/", authRoutes);
appSection.route("/", callbacks);
appSection.route("/", summary);
appSection.route("/", updates);
appSection.route("/", files);
// Note: /app/sync routes are mounted separately with appSyncRateLimiter.

// App sync section - public sync endpoints (user-authenticated)
// Auth runs before rate limiter to enable per-user keying (not per-IP)
const appSyncSection = new Hono<{ Bindings: Bindings }>();
appSyncSection.use(appCorsMiddleware);
appSyncSection.use("*", appSyncRateLimiter);
appSyncSection.use("*", trackerIdentifyMiddleware);
appSyncSection.route("/", appSync);

// SDK section - endpoints called by plot CLI
const sdkSection = new Hono<{ Bindings: Bindings }>();
sdkSection.use("*", generalRateLimiter);
sdkSection.use("*", sdkAuthMiddleware);
sdkSection.use("*", trackerIdentifyMiddleware);
sdkSection.route("/", twist);
sdkSection.route("/", priority);
sdkSection.route("/", tokens);

// Stripe section - webhook endpoints
const stripeSection = new Hono<{ Bindings: Bindings }>();
stripeSection.use("*", generalRateLimiter);
stripeSection.use("*", stripeMiddleware);
stripeSection.route("/", stripe);

// Mount all sections
app.route("/app", appSection);
app.route("/app", appSyncSection);
app.route("/v1", sdkSection);
app.route("/stripe", stripeSection);

// Mount webhook route at top level
app.route("/", webhook);

// Scheduled handler for cron triggers
async function scheduled(
  _event: ScheduledEvent,
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "scheduled" });

  try {
    // Use a singleton DO instance by using a fixed name
    const syncRecoveryId = env.SYNC_RECOVERY.idFromName("singleton");
    const syncRecoveryDO = env.SYNC_RECOVERY.get(syncRecoveryId);

    await syncRecoveryDO.fetch(
      new Request("http://do/trigger", { method: "POST" })
    );

    logger.info("Sync recovery triggered by cron");
  } catch (error) {
    logger.error("Error in scheduled handler", error as Error);
  }

  try {
    const privacyId = env.PRIVACY_REPORTING.idFromName("singleton");
    const privacyDO = env.PRIVACY_REPORTING.get(privacyId);
    await privacyDO.fetch(
      new Request("http://do/trigger", { method: "POST" })
    );
  } catch (error) {
    logger.error("Error in privacy reporting handler", error as Error);
  }
}

// Export app with queue and scheduled handlers
export default {
  ...(app as any),
  queue,
  scheduled,
};
