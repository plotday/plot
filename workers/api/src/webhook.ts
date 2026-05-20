import { Hono } from "hono";
import { render } from "@plotday/email";

import { Network } from "./twist/tools/network";
import { invokeWebhookCallback } from "./twist/invoke-webhook";
import { sendEmail } from "./email/send";
import type { Bindings } from "./env";
import { verifyPubSubToken } from "./utils/pubsub";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "./utils/log-context";
import { dbMiddleware } from "./middleware/db";
import {
  webhookAsyncRateLimiter,
  webhookRateLimiter,
} from "./middleware/rate-limit";
import {
  isCallbackError,
  getCallbackErrorType,
  type CallbackErrorType,
} from "./errors";
import { captureServerError } from "./utils/error-capture";
import { disposeRpc } from "./utils/rpc";

const webhook = new Hono<{ Bindings: Bindings }>();

/**
 * Verifies Svix webhook signature (used by Clerk).
 * https://docs.svix.com/receiving/verifying-payloads/how-manual
 */
async function verifySvixSignature(
  svixId: string,
  svixTimestamp: string,
  svixSignature: string,
  body: string,
  secret: string
): Promise<boolean> {
  // Check timestamp to prevent replay attacks (within 5 minutes)
  const currentTime = Math.floor(Date.now() / 1000);
  const requestTime = parseInt(svixTimestamp, 10);
  if (isNaN(requestTime) || Math.abs(currentTime - requestTime) > 300) {
    return false;
  }

  // Svix secret is prefixed with "whsec_" and base64-encoded
  const secretBytes = Uint8Array.from(
    atob(secret.startsWith("whsec_") ? secret.slice(6) : secret),
    (c) => c.charCodeAt(0)
  );

  const encoder = new TextEncoder();
  const baseString = `${svixId}.${svixTimestamp}.${body}`;

  const key = await crypto.subtle.importKey(
    "raw",
    secretBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(baseString)
  );

  const expectedSignature =
    "v1," +
    btoa(String.fromCharCode(...new Uint8Array(signatureBytes)));

  // svix-signature header may contain multiple space-separated signatures
  const signatures = svixSignature.split(" ");
  return signatures.some((sig) => sig === expectedSignature);
}

/** Map Clerk email template slugs to our email types and subjects */
const CLERK_EMAIL_MAP: Record<
  string,
  { emailType: Parameters<typeof render>[0]; subject: string; needsCode?: boolean }
> = {
  verification_code: {
    emailType: "email-confirmation",
    subject: "Verify your Plot email",
    needsCode: true,
  },
  reset_password_code: {
    emailType: "password-reset",
    subject: "Reset your Plot password",
    needsCode: true,
  },
  email_address_verification: {
    emailType: "email-change",
    subject: "Confirm your new email address",
    needsCode: true,
  },
  account_locked: {
    emailType: "account-locked",
    subject: "Your Plot account has been locked",
  },
  password_changed: {
    emailType: "password-changed",
    subject: "Your Plot password has been changed",
  },
  password_removed: {
    emailType: "password-removed",
    subject: "Your Plot password has been removed",
  },
  new_device_sign_in: {
    emailType: "new-device-sign-in",
    subject: "New sign-in to your Plot account",
  },
};

// Clerk webhook endpoint - handles email.created events for auth emails
webhook.post("/hook/clerk", dbMiddleware, webhookRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const svixId = c.req.header("svix-id");
    const svixTimestamp = c.req.header("svix-timestamp");
    const svixSignature = c.req.header("svix-signature");

    if (!svixId || !svixTimestamp || !svixSignature) {
      logger.warn("Clerk webhook missing Svix headers");
      return new Response("Unauthorized", { status: 401 });
    }

    const rawBody = await c.req.text();

    const isValid = await verifySvixSignature(
      svixId,
      svixTimestamp,
      svixSignature,
      rawBody,
      c.env.CLERK_WEBHOOK_SIGNING_SECRET
    );

    if (!isValid) {
      logger.warn("Clerk webhook signature verification failed");
      return new Response("Unauthorized", { status: 401 });
    }

    let body: any;
    try {
      body = JSON.parse(rawBody);
    } catch {
      logger.warn("Failed to parse Clerk webhook body");
      return new Response("Bad request", { status: 400 });
    }

    // Handle user.deleted events - delete user from database (cascades)
    if (body.type === "user.deleted") {
      const clerkId = body.data?.id;
      if (!clerkId) {
        logger.warn("Clerk user.deleted missing user id");
        return c.json({ ok: true });
      }

      try {
        const deleted = await c.var.db
          .deleteFrom("user")
          .where("clerk_id", "=", clerkId)
          .returning("id")
          .executeTakeFirst();

        if (deleted) {
          logger.info("Deleted user from database", {
            user_id: deleted.id,
            clerk_id: clerkId,
          });
        } else {
          logger.info("Clerk user.deleted but no matching user in database", {
            clerk_id: clerkId,
          });
        }
      } catch (error) {
        return captureServerError(c, error, "Failed to delete user from database", {
          clerk_id: clerkId,
        });
      }

      return c.json({ ok: true });
    }

    // Only handle email.created events below
    if (body.type !== "email.created") {
      return c.json({ ok: true });
    }

    const { slug, to_email_address, data } = body.data ?? {};

    if (!slug || !to_email_address) {
      logger.warn("Clerk email.created missing slug or to_email_address", {
        slug,
      });
      return c.json({ ok: true });
    }

    const mapping = CLERK_EMAIL_MAP[slug];
    if (!mapping) {
      logger.info("Unhandled Clerk email slug", { slug });
      return c.json({ ok: true });
    }

    // Render email - OTP emails need a code, notification emails don't
    let html: string;
    let text: string;
    let emailType = mapping.emailType;
    let subject = mapping.subject;

    if (mapping.needsCode) {
      const code =
        data?.otp_code ?? data?.verification_code ?? data?.code ?? "";

      if (!code) {
        logger.warn("Clerk email.created missing verification code", {
          slug,
          dataKeys: data ? Object.keys(data) : [],
        });
        return c.json({ ok: true });
      }

      // For verification_code, distinguish sign-up from sign-in verification.
      // Clerk uses the same slug for both; we check if the user was created
      // recently to determine if this is a new sign-up or an existing user
      // verifying a new device (Client Trust).
      if (slug === "verification_code") {
        const userCreatedAt = data?.user?.created_at;
        const isNewUser =
          userCreatedAt && Date.now() - userCreatedAt < 5 * 60 * 1000;

        if (!isNewUser) {
          emailType = "sign-in-verification";
          subject = "Your Plot sign-in code";
        }
      }

      ({ html, text } = await render(emailType as "email-confirmation", { code }));
    } else {
      ({ html, text } = await render(mapping.emailType as "account-locked"));
    }

    const result = await sendEmail(
      {
        from: "Plot <noreply@updates.plot.day>",
        to: [to_email_address],
        subject,
        html,
        text,
      },
      c.env.RESEND_API_KEY
    );

    if (!result.success) {
      return captureServerError(c, new Error(result.error || "Email send failed"), "Failed to send Clerk auth email", {
        slug,
        to: to_email_address,
      });
    }

    logger.info("Sent Clerk auth email", {
      slug,
      emailType: mapping.emailType,
      to: to_email_address,
    });

    return c.json({ ok: true });
  } catch (error) {
    return captureServerError(c, error, "Error processing Clerk webhook");
  }
});

/**
 * Verifies Slack webhook signature
 * https://api.slack.com/authentication/verifying-requests-from-slack
 */
async function verifySlackSignature(
  signature: string,
  timestamp: string,
  body: string,
  signingSecret: string
): Promise<boolean> {
  // Check timestamp to prevent replay attacks (within 5 minutes)
  const currentTime = Math.floor(Date.now() / 1000);
  const requestTime = parseInt(timestamp, 10);
  if (Math.abs(currentTime - requestTime) > 300) {
    return false;
  }

  // Compute the expected signature
  const baseString = `v0:${timestamp}:${body}`;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(signingSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(baseString)
  );

  // Convert to hex string
  const expectedSignature =
    "v0=" +
    Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

  // Constant-time comparison
  return signature === expectedSignature;
}

// Slack webhook endpoint - handles Events API webhooks with team-based routing
webhook.post("/hook/slack", webhookRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const signature = c.req.header("x-slack-signature");
    const timestamp = c.req.header("x-slack-request-timestamp");

    if (!signature || !timestamp) {
      logger.warn("Slack webhook missing signature or timestamp");
      return new Response("Unauthorized", { status: 401 });
    }

    // Get raw body for signature verification
    const rawBody = await c.req.text();

    // Verify signature
    const isValid = await verifySlackSignature(
      signature,
      timestamp,
      rawBody,
      c.env.AUTH_SLACK_SIGNING_SECRET
    );

    if (!isValid) {
      logger.warn("Slack webhook signature verification failed");
      return new Response("Unauthorized", { status: 401 });
    }

    // Parse body
    let body: any;
    try {
      body = JSON.parse(rawBody);
    } catch (error) {
      logger.warn("Failed to parse Slack webhook body", error as Error);
      return new Response("Bad request", { status: 400 });
    }

    // Handle Slack challenge verification
    if (body.type === "url_verification" && body.challenge) {
      return c.json({ challenge: body.challenge });
    }

    // Extract headers for callback
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.header())) {
      headers[key] = value;
    }

    // Get URL parameters
    const url = new URL(c.req.url);
    const params: Record<string, string> = {};
    url.searchParams.forEach((value, key) => {
      params[key] = value;
    });

    // Fan out to the webhook queue: one WebhookMessage per matching
    // callback. Previously this awaited every callback in-request via
    // Promise.allSettled, so one slow handler would stall Slack's HTTP
    // window and its failure would contaminate the others. Each message
    // now retries independently through Cloudflare Queues.
    const teamId = body.team_id;
    const eventType = body.event?.type;
    if (!teamId || !eventType) {
      logger.warn("Slack webhook missing team_id or event type", {
        has_team_id: Boolean(teamId),
        has_event_type: Boolean(eventType),
      });
      return c.json({ ok: true });
    }

    const matchingTokens = await Network.GetSlackCallbacks(
      c.env.CALLBACKS,
      teamId,
      eventType
    );

    if (matchingTokens.length === 0) {
      logger.info("No Slack callbacks match event", {
        team_id: teamId,
        event_type: eventType,
      });
      return c.json({ ok: true });
    }

    await Promise.all(
      matchingTokens.map((token) =>
        c.env.WEBHOOK_QUEUE.send({
          type: "webhook",
          token,
          method: "POST",
          headers,
          params,
          body,
        })
      )
    );

    return c.json({ ok: true });
  } catch (error) {
    logger.error("Error processing Slack webhook", error as Error);
    // Still return 200 OK to prevent Slack from disabling the webhook
    return c.json({ ok: true });
  }
});

// Gmail webhook endpoint - handles Google Pub/Sub push notifications
webhook.post("/hook/gmail/:topicId", webhookAsyncRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const authHeader = c.req.header("authorization");

    // Verify Pub/Sub JWT token.
    // Return 200 on auth failure to prevent Pub/Sub retry storm.
    const isValid = await verifyPubSubToken(authHeader, c.env.GCP_PROJECT_ID);
    if (!isValid) {
      logger.warn("Gmail webhook missing or invalid authorization");
      return c.json({ ok: false, error: "unauthorized" });
    }

    // Get topic ID from URL (format: gmail-{callbackToken})
    const topicId = c.req.param("topicId");
    if (!topicId) {
      return c.json({ ok: false, error: "missing topicId" });
    }

    // Decode callback token from topic ID
    // Topic ID format: "gmail-{callbackToken}" where ":" in the token is encoded as "."
    // because colons are invalid in Pub/Sub topic names.
    const rawToken = topicId.startsWith("gmail-")
      ? topicId.substring(6) // Remove "gmail-" prefix
      : topicId; // Fallback for backward compatibility
    const callbackToken = rawToken.replaceAll(".", ":");

    if (!callbackToken) {
      return c.json({ ok: false, error: "invalid topicId format" });
    }

    // Parse Pub/Sub message
    let body: any;
    try {
      body = await c.req.json();
    } catch (error) {
      logger.warn("Failed to parse Gmail webhook body", error as Error);
      return new Response("Bad request", { status: 400 });
    }

    // Pub/Sub push messages have a specific format
    // https://cloud.google.com/pubsub/docs/push#receiving_messages
    const message = body.message;
    if (!message) {
      logger.warn("Gmail webhook missing message field");
      return new Response("Bad request (missing message)", { status: 400 });
    }

    // Decode base64-encoded message data
    let decodedData: any = {};
    if (message.data) {
      try {
        const decoded = atob(message.data);
        decodedData = JSON.parse(decoded);
      } catch (error) {
        logger.warn("Failed to decode Gmail webhook message data", error as Error);
        // Continue with empty data - the callback might not need it
      }
    }

    // Extract headers for callback
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.header())) {
      headers[key] = value;
    }

    // Get URL parameters
    const url = new URL(c.req.url);
    const params: Record<string, string> = {};
    url.searchParams.forEach((value, key) => {
      params[key] = value;
    });

    // Enqueue to WEBHOOK_QUEUE for bounded-concurrency async processing.
    // Dispatching synchronously to the per-twist_instance CallbacksState DO
    // held the DO's input gate through the full callback path (DB queries →
    // factory → twist RPC → twist's own RPCs back to this worker). Pub/Sub
    // bursts piled webhooks onto the same DO until its storage watchdog
    // tripped with "Durable Object storage operation exceeded timeout".
    // The queue consumer in queue/webhook.ts dispatches with max_concurrency
    // 5 and retries transient failures via Cloudflare Queues.
    await c.env.WEBHOOK_QUEUE.send({
      type: "webhook",
      token: callbackToken,
      method: "POST",
      headers,
      params,
      body: {
        ...body, // Include original Pub/Sub message
        decodedData, // Add decoded message data for convenience
      },
    });

    // Always return 200 OK to acknowledge the message to Pub/Sub.
    return c.json({ ok: true });
  } catch (error) {
    return captureServerError(c, error, "Error processing Gmail webhook");
  }
});

// Generic Pub/Sub webhook endpoint - handles push notifications from any Google service
// (Google Chat via Workspace Events, and future services). Gmail keeps its own route
// for backward compatibility with existing Pub/Sub subscriptions.
webhook.post("/hook/pubsub/:topicId", webhookAsyncRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const authHeader = c.req.header("authorization");

    // Verify Pub/Sub JWT token.
    // Return 200 on auth failure to acknowledge the message and prevent
    // Pub/Sub from retrying indefinitely — a retried invalid token won't
    // become valid, so retries just create a storm.
    const isValid = await verifyPubSubToken(authHeader, c.env.GCP_PROJECT_ID);
    if (!isValid) {
      logger.warn("Pub/Sub webhook missing or invalid authorization");
      return c.json({ ok: false, error: "unauthorized" });
    }

    // Get topic ID from URL (format: {prefix}-{callbackToken})
    const topicId = c.req.param("topicId");
    if (!topicId) {
      return c.json({ ok: false, error: "missing topicId" });
    }

    // Extract callback token by stripping the provider prefix.
    // Callback tokens use ":" as a separator (doId:token) which was encoded as "."
    // in the topic name because colons are invalid in Pub/Sub topic names.
    const prefixes = ["ps-", "gmail-"];
    let callbackToken = topicId;
    for (const prefix of prefixes) {
      if (topicId.startsWith(prefix)) {
        callbackToken = topicId.substring(prefix.length);
        break;
      }
    }
    callbackToken = callbackToken.replaceAll(".", ":");

    if (!callbackToken) {
      return c.json({ ok: false, error: "invalid topicId format" });
    }

    // Parse Pub/Sub message
    let body: any;
    try {
      body = await c.req.json();
    } catch (error) {
      logger.warn("Failed to parse Pub/Sub webhook body", error as Error);
      return new Response("Bad request", { status: 400 });
    }

    // Pub/Sub push messages have a specific format
    // https://cloud.google.com/pubsub/docs/push#receiving_messages
    const message = body.message;
    if (!message) {
      logger.warn("Pub/Sub webhook missing message field");
      return new Response("Bad request (missing message)", { status: 400 });
    }

    // Decode base64-encoded message data
    let decodedData: any = {};
    if (message.data) {
      try {
        const decoded = atob(message.data);
        decodedData = JSON.parse(decoded);
      } catch (error) {
        logger.warn("Failed to decode Pub/Sub message data", error as Error);
        // Continue with empty data - the callback might not need it
      }
    }

    // Extract headers for callback
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.header())) {
      headers[key] = value;
    }

    // Get URL parameters
    const url = new URL(c.req.url);
    const params: Record<string, string> = {};
    url.searchParams.forEach((value, key) => {
      params[key] = value;
    });

    // Enqueue to WEBHOOK_QUEUE for bounded-concurrency async processing (see
    // Gmail webhook above for rationale). Workspace Events delivers the
    // CloudEvent type via Pub/Sub message attributes (e.g. "ce-type":
    // "google.workspace.chat.message.v1.created"), so merge attributes into
    // decodedData for the connector to access.
    const attributes = message.attributes as Record<string, string> | undefined;
    await c.env.WEBHOOK_QUEUE.send({
      type: "webhook",
      token: callbackToken,
      method: "POST",
      headers,
      params,
      body: {
        ...body,
        decodedData: {
          ...decodedData,
          ...(attributes?.["ce-type"] ? { type: attributes["ce-type"] } : {}),
          ...(attributes ? { attributes } : {}),
        },
      },
    });

    // Always return 200 OK to acknowledge the message to Pub/Sub.
    return c.json({ ok: true });
  } catch (error) {
    return captureServerError(c, error, "Error processing Pub/Sub webhook");
  }
});

/**
 * Extract webhook request data into a form that can be either (a) dispatched
 * synchronously via `invokeWebhookCallback` or (b) serialized onto
 * WEBHOOK_QUEUE for async processing.
 */
async function parseWebhookRequest(
  c: any,
  logger: ReturnType<typeof createLogger>
): Promise<{
  method: string;
  headers: Record<string, string>;
  params: Record<string, string>;
  body: any;
  rawBody?: string;
}> {
  const method = c.req.method;
  const headers: Record<string, string> = {};
  for (const [key, value] of Object.entries(c.req.header())) {
    headers[key] = value as string;
  }

  const url = new URL(c.req.url);
  const params: Record<string, string> = {};
  url.searchParams.forEach((value, key) => {
    params[key] = value;
  });

  let rawBody: string | undefined = undefined;
  let body: any = null;

  if (method !== "GET" && method !== "HEAD") {
    rawBody = await c.req.text();
    body = parseBodyFromRaw(rawBody, headers["content-type"], logger);
  }

  return { method, headers, params, body, rawBody };
}

/**
 * Re-parse a webhook body from its raw string + Content-Type. Used by both
 * `parseWebhookRequest` and the WEBHOOK_QUEUE consumer (the generic /hook
 * producer omits the parsed `body` from queue messages to avoid duplicating
 * `rawBody` and tripping Cloudflare Queues' 128 KB message limit).
 */
export function parseBodyFromRaw(
  rawBody: string | undefined,
  contentType: string | undefined,
  logger: ReturnType<typeof createLogger>
): any {
  if (rawBody === undefined) return null;
  try {
    if (contentType?.includes("application/json")) {
      return JSON.parse(rawBody);
    }
    if (contentType?.includes("application/x-www-form-urlencoded")) {
      return Object.fromEntries(new URLSearchParams(rawBody).entries());
    }
    return rawBody;
  } catch (error) {
    logger.warn("Failed to parse callback request body", error as Error);
    return rawBody;
  }
}

/**
 * Build a Hono response from a callback's return value.
 *
 * - `undefined` / `null` → plain "OK" text (matches the original behavior for
 *   fire-and-forget callbacks).
 * - `string` → `text/plain` with the string as the body. Required by providers
 *   that validate webhook endpoints with an echo challenge, e.g. Microsoft
 *   Graph subscription creation, which POSTs with a `validationToken` query
 *   param and expects the token returned verbatim as plain text.
 * - anything else → JSON.
 */
function respondWithCallbackResult(c: any, result: unknown): Response {
  if (result === undefined || result === null) {
    return new Response("OK", { status: 200 });
  }
  if (typeof result === "string") {
    return new Response(result, {
      status: 200,
      headers: { "content-type": "text/plain" },
    });
  }
  // @ts-ignore — c.json accepts arbitrary JSON-serializable values
  return c.json(result);
}

/**
 * Map a `CallbackError` thrown from the DO path to an HTTP response for
 * synchronous webhook dispatch. Shared between the /hook-sync/:token route and
 * any future inline dispatch paths.
 */
function respondToCallbackError(
  c: any,
  error: unknown,
  logger: ReturnType<typeof createLogger>
): Response {
  const statusMap: Record<CallbackErrorType, number> = {
    INVALID_TOKEN_FORMAT: 400,
    INVALID_TOKEN: 400,
    NOT_FOUND: 410, // 410 Gone — tells providers (Google, etc.) to stop retrying
    EXPIRED: 410,
    SUSPENDED: 503,
    UNINITIALIZED: 500,
  };

  const errorType = getCallbackErrorType(error as Error);
  if (!errorType) {
    return captureServerError(c, error, "CallbackError missing type");
  }

  const status = statusMap[errorType];

  // Log only for actual errors, not expected conditions.
  if (errorType !== "NOT_FOUND" && errorType !== "EXPIRED") {
    logger.warn("Callback error", {
      errorType,
      errorName: (error as Error).name,
      message: (error as Error).message,
      ...(error as any).context,
    });
  }

  const message = (error as Error).message.replace(/^CallbackError: /, "");
  return new Response(message, { status });
}

// Default generic webhook endpoint — enqueues to WEBHOOK_QUEUE and returns
// 200 immediately. This is the path returned from `network.createWebhook()`
// unless the caller explicitly passes `{ async: false }`. The queue consumer
// (`workers/api/src/queue/webhook.ts`) dispatches each message into the
// CallbacksState DO with bounded concurrency, so bursts of webhook traffic
// can't exhaust Postgres connections.
//
// Also mounted at `/hook-async/:token` as a legacy alias: an earlier version
// of `Network.tokenToUrl` emitted `/hook-async/` URLs that external providers
// (Google Calendar push, etc.) stored. Those registrations keep arriving until
// the connector re-subscribes, so route them here rather than 404.
const enqueueWebhookHandler = async (c: any) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    const { method, headers, params, body, rawBody } =
      await parseWebhookRequest(c, logger);

    // Send only rawBody (needed verbatim for signature verification by
    // connectors) — the consumer re-parses body from rawBody + headers.
    // Including both fields effectively halves the per-message budget,
    // pushing ~64 KB+ webhooks over Cloudflare Queues' 128 KB limit and
    // surfacing as "Queue send failed: Payload Too Large".
    try {
      await c.env.WEBHOOK_QUEUE.send({
        type: "webhook",
        token,
        method,
        headers,
        params,
        rawBody,
      });
      return c.json({ queued: true });
    } catch (sendError) {
      const sendMsg = (sendError as Error)?.message ?? "";
      if (!sendMsg.includes("Payload Too Large")) {
        throw sendError;
      }
      // Fallback: webhook payload is too large even after dropping the
      // parsed body. Dispatch inline so the callback isn't dropped. This
      // path bypasses the queue's bounded concurrency, but it's reached
      // only when no other option exists (drop the webhook entirely).
      logger.warn("Webhook payload too large for queue, dispatching inline", {
        rawBodyBytes: rawBody?.length ?? 0,
      });
      c.executionCtx.waitUntil(
        (async () => {
          try {
            const result = await invokeWebhookCallback(c.env, c.executionCtx, token, {
              method,
              headers,
              params,
              body,
              rawBody,
            });
            // invokeWebhookCallback may return an RPC stub; dispose it.
            disposeRpc(result);
          } catch (inlineError) {
            logger.error(
              "Inline webhook dispatch failed after queue overflow",
              inlineError as Error
            );
          }
        })()
      );
      return c.json({ queued: false, dispatched: "inline" });
    }
  } catch (error) {
    return captureServerError(c, error, "Error enqueueing webhook");
  }
};

webhook.all(Network.PATH, webhookAsyncRateLimiter, enqueueWebhookHandler);
webhook.all("/hook-async/:token", webhookAsyncRateLimiter, enqueueWebhookHandler);

// Synchronous webhook endpoint — callers opt in by passing `{ async: false }`
// to `network.createWebhook()`. Used by connectors that must return a
// response body the sender reads (e.g. Microsoft Graph validation echo) or
// need per-request success/failure status codes propagated back.
webhook.all("/hook-sync/:token", webhookRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    const { method, headers, params, body, rawBody } =
      await parseWebhookRequest(c, logger);

    using result = await invokeWebhookCallback(
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] },
      token,
      { method, headers, params, body, rawBody }
    );

    return respondWithCallbackResult(c, result);
  } catch (error) {
    if (isCallbackError(error)) {
      return respondToCallbackError(c, error, logger);
    }
    return captureServerError(c, error, "Error processing callback");
  }
});

export default webhook;
