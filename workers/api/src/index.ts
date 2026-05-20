import { Container } from "@cloudflare/containers";
import { Hono } from "hono";
import { PostHog } from "posthog-node";

import { Tracker } from "./utils/tracker";
import account from "./app/account";
import admin from "./app/admin";
import device from "./app/device";
import invitation from "./app/invitation";
import twists from "./app/twists";
import twistIntegrations from "./app/twist-integrations";
// Import app routes and middleware
import { authMiddleware as appAuthMiddleware } from "./app/auth";
import authBridgeRoutes from "./app/authBridge";
import authRoutes from "./app/authRoutes";
import slackInstallRoutes from "./app/slackInstall";
import callbacks from "./app/callbacks";
import connections from "./app/connections";
import linkEmail from "./app/link-email";
import threadShare from "./app/thread-share";
import groupRoutes from "./app/group";
import topicRoutes from "./app/topic";
import { corsMiddleware as appCorsMiddleware } from "./app/cors";
import favicon from "./app/favicon";
import linkMetadata from "./app/link-metadata";
import files from "./app/files";
import upgrade from "./app/upgrade";
import aiKeyRoutes from "./app/ai-keys";
import teamRoutes from "./app/team";
import appSync from "./app/sync";
import notificationContent from "./app/notification-content";
import notificationSummary from "./app/notification-summary";
import testRoutes from "./app/test-routes";
import testSignIn from "./app/test-signin";
import summary from "./app/summary";
import updates from "./app/updates";
import unsubscribe from "./app/unsubscribe";
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
import { dbMiddleware } from "./middleware/db";
import { withDb } from "./db";
import { syncUserTwistStats } from "./utils/twist-stats";
import { refreshAllChannels } from "./scheduled/refresh-channels";
import { recoverPendingConnections } from "./scheduled/recover-pending-connections";
import { finalizeEventSessions } from "./scheduled/finalize-event-sessions";
import { runSweep as runClassifySweep } from "./state/classify-thread";
// Import webhook routes
import webhook from "./webhook";
// Import rate limiting middleware
import {
  generalRateLimiter,
  appSyncRateLimiter,
  sdkRateLimiter,
} from "./middleware/rate-limit";

// Export Durable Objects
export { Storage } from "./state/storage";
export { CallbacksState } from "./state/callbacks";
export { Broadcast } from "./state/broadcast";
export { Usage } from "./state/usage";
export { UserAiUsage } from "./state/user-ai-usage";
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
export { PushNotify } from "./state/push-notify";
export { EmailNotify } from "./state/email-notify";
export { ChannelRouter } from "./state/channel-router";

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

// dbMiddleware is applied per-section (below) rather than globally so that
// high-volume webhook routes that don't read the DB from the request context
// (e.g. /hook/:token, which dispatches straight into the CallbacksState DO)
// don't allocate a pg.Pool per request.

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
    "http://localhost:5173",
    "http://localhost:8788",
    "https://preview.plot.day",
    "https://app.plot.day",
    "https://plot.day",
  ];

  if (origin && allowedOrigins.includes(origin)) {
    c.header("Access-Control-Allow-Origin", origin);
    c.header("Access-Control-Allow-Credentials", "true");
  }

  return c.json({ error: "Internal Server Error" }, 500);
});

// App section - endpoints called by the Flutter app
const appSection = new Hono<{ Bindings: Bindings }>();
appSection.use("*", dbMiddleware);
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
appSection.route("/", twists);
appSection.route("/", twistIntegrations);
appSection.route("/", authRoutes);
appSection.route("/", callbacks);
appSection.route("/", notificationContent);
appSection.route("/", notificationSummary);
appSection.route("/", testRoutes);
appSection.route("/", summary);
appSection.route("/", updates);
appSection.route("/", favicon);
appSection.route("/", linkMetadata);
appSection.route("/", files);
appSection.route("/", upgrade);
appSection.route("/", connections);
appSection.route("/", teamRoutes);
appSection.route("/", aiKeyRoutes);
appSection.route("/", linkEmail);
appSection.route("/", threadShare);
appSection.route("/", groupRoutes);
appSection.route("/", topicRoutes);
// Note: /app/sync routes are mounted separately with appSyncRateLimiter.

// App sync section - public sync endpoints (user-authenticated)
// Auth runs before rate limiter to enable per-user keying (not per-IP)
const appSyncSection = new Hono<{ Bindings: Bindings }>();
appSyncSection.use("*", dbMiddleware);
appSyncSection.use(appCorsMiddleware);
appSyncSection.use("*", appSyncRateLimiter);
appSyncSection.use("*", trackerIdentifyMiddleware);
appSyncSection.route("/", appSync);

// SDK section - endpoints called by plot CLI
const sdkSection = new Hono<{ Bindings: Bindings }>();
sdkSection.use("*", dbMiddleware);
sdkSection.use("*", sdkRateLimiter);
sdkSection.use("*", sdkAuthMiddleware);
sdkSection.use("*", trackerIdentifyMiddleware);
sdkSection.route("/", twist);
sdkSection.route("/", priority);
sdkSection.route("/", tokens);

// Stripe section - webhook endpoints
const stripeSection = new Hono<{ Bindings: Bindings }>();
stripeSection.use("*", dbMiddleware);
stripeSection.use("*", generalRateLimiter);
stripeSection.use("*", stripeMiddleware);
stripeSection.route("/", stripe);

// Mount all sections
app.route("/app", appSection);
app.route("/app", appSyncSection);
app.route("/v1", sdkSection);
app.route("/stripe", stripeSection);

// Health check — exercises DB to detect connection exhaustion
app.get("/health", dbMiddleware, async (c) => {
  await c.var.db.selectFrom("priority").select("id").limit(1).execute();
  return c.text("ok");
});

// Public unsubscribe endpoint — token-authenticated, no session required
app.route("/", unsubscribe);

// Admin endpoints — gated by ADMIN_API_KEY bearer token (no app/sdk auth).
app.route("/", admin);

// Mount webhook route at top level
app.route("/", webhook);

// OAuth bridge — public endpoint hit by the provider's browser redirect
// (no user-auth context), so it must live outside the /app section.
app.route("/", authBridgeRoutes);

// Public Slack admin-install entry point (plot.day/slack button target).
app.route("/", slackInstallRoutes);

// Server-issued sign-in ticket for allowlisted shared test accounts. Public
// because the caller isn't signed in yet; password is verified server-side
// via the Clerk Backend API. See workers/api/src/app/test-signin.ts.
app.route("/", testSignIn);

// Scheduled handler for cron triggers
async function scheduled(
  event: ScheduledEvent,
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

  // Trial expiry is now driven by Stripe's customer.subscription.deleted
  // webhook (trial_settings.end_behavior='cancel'). No fallback sweep needed.

  // Fail-closed belt-and-suspenders: archive any stuck Twisting tag (tag_id
  // 109) whose row hasn't been touched in over an hour. The queue handler's
  // per-batch `finally` in workers/api/src/queue/updates.ts is the primary
  // cleanup path; this only fires when a worker crashed or a message was lost
  // mid-dispatch. 1 hour is well beyond any realistic twist runtime (including
  // long LLM / agentic chains) so we never prematurely clear a legitimate
  // "thinking" indicator.
  try {
    await withDb(env, async (db) => {
      const result = await db
        .updateTable("note_tag")
        .set({ archived_at: new Date() as any, updated_by: 0 })
        .where("tag_id", "=", 109)
        .where("archived_at", "is", null)
        .where(
          "updated_at",
          "<",
          new Date(Date.now() - 60 * 60 * 1000) as any
        )
        .executeTakeFirst();

      const rows = Number(result.numUpdatedRows ?? 0);
      if (rows > 0) {
        logger.warn("Cron cleared stuck Twisting tags", { count: rows });
      }
    });
  } catch (error) {
    logger.error(
      "Error in stuck Twisting tag cleanup",
      error as Error
    );
  }

  // Periodic sweep (every 30 min): synthesize recovery dispatches for
  // connections flagged `recovery_pending = true` whose auth has been
  // repaired. Backstop for cases where the onAuth recovery dispatch was
  // expected to fire on re-auth but didn't (queue exhaustion, DO timeout,
  // worker crash). Without this, an affected connection would stay stuck
  // until the user toggled a channel.
  const scheduledTime = new Date(event.scheduledTime);
  const scheduledMinutes = scheduledTime.getUTCMinutes();
  if (scheduledMinutes < 5 || (scheduledMinutes >= 30 && scheduledMinutes < 35)) {
    try {
      await recoverPendingConnections(env, _ctx);
    } catch (error) {
      logger.error("Error in recovery sweep", error as Error);
    }
  }

  // Every tick (~5 min): finalize ended event occurrences into
  // `source='event'` Session rows so weekly priority totals reflect time
  // spent on events even when the user's app was closed. Idempotent.
  try {
    await finalizeEventSessions(env, _ctx);
  } catch (error) {
    logger.error("Error in event session finalizer", error as Error);
  }

  // Hourly: re-enqueue every thread_priority row where classify_at is
  // past 1h ago (queue retries exhausted). Bounded at 1000 rows/run;
  // larger backlogs drain over multiple ticks. Gated to the first
  // 5 minutes of each hour because the cron runs every 5 min.
  if (scheduledMinutes < 5) {
    try {
      await withDb(env, async (db) => {
        const result = await runClassifySweep(db, env);
        if (result.enqueued > 0) {
          logger.info("classify sweep enqueued pending rows", {
            enqueued: result.enqueued,
            oldest_classify_at: result.oldestClassifyAt,
          });
        }
      });
    } catch (error) {
      logger.error("Error in classify sweep", error as Error);
    }
  }

  // Daily sweep: re-discover external channels for every active connection so
  // newly-created Slack channels / Airtable bases / Linear projects show up
  // automatically. When the per-connection auto-enable flag is on, new
  // channels are also enabled in the same call.
  if (scheduledTime.getUTCHours() === 5 && scheduledTime.getUTCMinutes() < 5) {
    try {
      await refreshAllChannels(env, _ctx);
    } catch (error) {
      logger.error("Error in periodic channel refresh", error as Error);
    }
  }

  // Daily sweep: refresh PostHog person properties with each user's active
  // connector and twist counts. Cron fires every 5 minutes, so we gate to a
  // single window (07:00-07:04 UTC) to run once per day.
  if (scheduledTime.getUTCHours() === 7 && scheduledTime.getUTCMinutes() < 5) {
    const postHog = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST,
      flushAt: 20,
      flushInterval: 1000,
    });
    const tracker = new Tracker(postHog);
    try {
      await withDb(env, async (db) => {
        const owners = await db
          .selectFrom("twist_instance")
          .select("owner_id")
          .where("archived_at", "is", null)
          .where("suspended_at", "is", null)
          .where("draft", "=", false)
          .distinct()
          .execute();

        for (const { owner_id } of owners) {
          try {
            await syncUserTwistStats(db, tracker, owner_id);
          } catch (error) {
            logger.error("Failed to sync twist stats for user", error as Error, {
              user_id: owner_id,
            });
          }
        }

        logger.info("Daily twist stats sweep complete", { count: owners.length });
      });
    } catch (error) {
      logger.error("Error in daily twist stats sweep", error as Error);
    } finally {
      await postHog.shutdown();
    }
  }
}

// Export app with queue and scheduled handlers
export default {
  ...(app as any),
  queue,
  scheduled,
};
