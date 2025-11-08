import { Container } from "@cloudflare/containers";
import { Hono } from "hono";
import { PostHog } from "posthog-node";

import account from "./app/account";
import agents from "./app/agents";
// Import app routes and middleware
import { authMiddleware as appAuthMiddleware } from "./app/auth";
import authRoutes from "./app/authRoutes";
import callbacks from "./app/callbacks";
import { corsMiddleware as appCorsMiddleware } from "./app/cors";
import summary from "./app/summary";
import updates from "./app/updates";
import type { Bindings } from "./env";
import { queue } from "./queue";
import agent from "./sdk/agent";
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
// Import webhook routes
import webhook from "./webhook";

// Export Durable Objects
export { Storage } from "./state/storage";
export { CallbacksState } from "./state/callbacks";
export { Broadcast } from "./state/broadcast";
export { Usage } from "./state/usage";
export { LogSubscriptions } from "./state/log-subscriptions";
export { HttpProxy } from "./agent/http-proxy";
export { LogStream } from "./state/log-stream";
export { AgentTail } from "./agent/tail";

export class AgentBuilder extends Container {
  defaultPort = 3000;
  sleepAfter = "60m";
}

// Export types for external use
export type {
  ActivityItem,
  PriorityItem,
  SessionItem,
  UpdateItem,
} from "./types";
export type { DatabaseUpdateRequest } from "./sync/database";

// Create main app
const app = new Hono<{ Bindings: Bindings }>();

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

// Add error handler for PostHog error tracking
app.onError(async (err, c) => {
  try {
    console.error(err);
    c.var.postHog.captureException(err, undefined, {
      path: c.req.path,
      method: c.req.method,
      url: c.req.url,
    });
  } catch (e) {
    console.error("Failed to capture exception in PostHog:", e);
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
appSection.use(appCorsMiddleware);
appSection.use("*", appAuthMiddleware);
appSection.route("/", account);
appSection.route("/", agents);
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
sdkSection.use("*", sdkAuthMiddleware);
sdkSection.route("/", agent);
sdkSection.route("/", priority);
sdkSection.route("/", tokens);

// Stripe section - webhook endpoints
const stripeSection = new Hono<{ Bindings: Bindings }>();
stripeSection.use("*", stripeMiddleware);
stripeSection.route("/", stripe);

// Mount all sections
app.route("/app", appSection);
app.route("/sync", syncSection);
app.route("/v1", sdkSection);
app.route("/stripe", stripeSection);

// Mount webhook route at top level
app.route("/", webhook);

// Export app with queue handler
export default {
  ...(app as any),
  queue,
};
