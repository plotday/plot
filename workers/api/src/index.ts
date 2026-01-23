import { Container } from "@cloudflare/containers";
import { Hono } from "hono";
import { PostHog } from "posthog-node";

import account from "./app/account";
import invitation from "./app/invitation";
import share from "./app/share";
import twists from "./app/twists";
// Import app routes and middleware
import { authMiddleware as appAuthMiddleware } from "./app/auth";
import authRoutes from "./app/authRoutes";
import callbacks from "./app/callbacks";
import { corsMiddleware as appCorsMiddleware } from "./app/cors";
import summary from "./app/summary";
import updates from "./app/updates";
import type { Bindings } from "./env";
import { postHogIdentifyMiddleware } from "./middleware/posthog-identify";
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
// Import sync routes and middleware
import { authMiddleware as syncAuthMiddleware } from "./sync/auth";
import database from "./sync/database";
import { createLogger } from "./utils/logger";
import { extractRequestContext, extractErrorContext, mergeContext } from "./utils/log-context";
import { disposeRpc } from "./utils/rpc";
// Import webhook routes
import webhook from "./webhook";
// Import rate limiting middleware
import { generalRateLimiter } from "./middleware/rate-limit";

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
export { SyncRecovery } from "./state/sync-recovery";

export class TwistBuilder extends Container {
  defaultPort = 3000;
  sleepAfter = "60m";
}

// Create main app
const app = new Hono<{ Bindings: Bindings }>();

// Apply request ID middleware first (for trace correlation)
app.use("*", requestIdMiddleware);

// Apply PostHog middleware
app.use("*", async (c, next) => {
  const postHog = new PostHog(c.env.POSTHOG_API_KEY, {
    host: c.env.POSTHOG_HOST,
    flushAt: 5,
    flushInterval: 10,
  });
  c.set("postHog", postHog);
  try {
    await next();
  } finally {
    // This runs after response, even if there's an error
    c.executionCtx.waitUntil(postHog.shutdown());
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
    c.var.postHog.captureException(err, undefined, {
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
appSection.use("*", generalRateLimiter);
appSection.use(appCorsMiddleware);
appSection.use("*", appAuthMiddleware);
appSection.use("*", postHogIdentifyMiddleware);
appSection.route("/", account);
appSection.route("/", invitation);
appSection.route("/", share);
appSection.route("/", twists);
appSection.route("/", authRoutes);
appSection.route("/", callbacks);
appSection.route("/", summary);
appSection.route("/", updates);

// Sync section - internal endpoints called from DB triggers
const syncSection = new Hono<{ Bindings: Bindings }>();
syncSection.use("*", syncAuthMiddleware);
syncSection.route("/", database);

// SDK section - endpoints called by plot CLI
const sdkSection = new Hono<{ Bindings: Bindings }>();
sdkSection.use("*", generalRateLimiter);
sdkSection.use("*", sdkAuthMiddleware);
sdkSection.use("*", postHogIdentifyMiddleware);
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
app.route("/sync", syncSection);
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

    const result = await syncRecoveryDO.fetch(
      new Request("http://do/trigger", { method: "POST" })
    );
    disposeRpc(result);

    logger.info("Sync recovery triggered by cron");
  } catch (error) {
    logger.error("Error in scheduled handler", error as Error);
  }
}

// Export app with queue and scheduled handlers
export default {
  ...(app as any),
  queue,
  scheduled,
};
