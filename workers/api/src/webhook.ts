import { Hono } from "hono";
import { render } from "@plotday/email";

import { Network } from "./twist/tools/network";
import { sendEmail } from "./email/send";
import type { Bindings } from "./env";
import { verifyPubSubToken } from "./utils/pubsub";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "./utils/log-context";
import { webhookRateLimiter } from "./middleware/rate-limit";
import {
  isCallbackError,
  getCallbackErrorType,
  type CallbackErrorType,
} from "./errors";
import { captureServerError } from "./utils/error-capture";

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
webhook.post("/hook/clerk", webhookRateLimiter, async (c) => {
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

    // Route to callbacks
    using _slackResult = await Network.HandleSlackWebhook(c.env.CALLBACKS, {
      method: "POST",
      headers,
      params,
      body,
    });

    // Always return 200 OK to Slack (as per plan)
    return c.json({ ok: true });
  } catch (error) {
    logger.error("Error processing Slack webhook", error as Error);
    // Still return 200 OK to prevent Slack from disabling the webhook
    return c.json({ ok: true });
  }
});

// Gmail webhook endpoint - handles Google Pub/Sub push notifications
webhook.post("/hook/gmail/:topicId", webhookRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const authHeader = c.req.header("authorization");

    // Verify Pub/Sub JWT token
    const isValid = await verifyPubSubToken(authHeader, c.env.GCP_PROJECT_ID);
    if (!isValid) {
      logger.warn("Gmail webhook missing or invalid authorization");
      return new Response("Unauthorized", { status: 401 });
    }

    // Get topic ID from URL (format: gmail-{callbackToken})
    const topicId = c.req.param("topicId");
    if (!topicId) {
      return new Response("Bad request (missing topicId)", { status: 400 });
    }

    // Decode callback token from topic ID
    // Topic ID format: "gmail-{callbackToken}"
    const callbackToken = topicId.startsWith("gmail-")
      ? topicId.substring(6) // Remove "gmail-" prefix
      : topicId; // Fallback for backward compatibility

    if (!callbackToken) {
      return new Response("Bad request (invalid topicId format)", {
        status: 400,
      });
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

    // Construct callback request with decoded data
    const webhookRequest = {
      method: "POST",
      headers,
      params,
      body: {
        ...body, // Include original Pub/Sub message
        decodedData, // Add decoded message data for convenience
      },
    };

    // Call the callback using the decoded token
    // The callback token encodes the DO shard and callback info
    using _gmailResult = await Network.HandleGmailWebhook(
      c.env.CALLBACKS,
      callbackToken,
      webhookRequest
    );

    // Always return 200 OK to acknowledge message
    return c.json({ ok: true });
  } catch (error) {
    // Return 500 to indicate failure, so Pub/Sub will retry
    return captureServerError(c, error, "Error processing Gmail webhook");
  }
});

// Webhook endpoint - handles all HTTP methods for webhook URLs
webhook.all(Network.PATH, webhookRateLimiter, async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    // Extract request data
    const method = c.req.method;
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

    // Get raw body first (for signature verification)
    let rawBody: string | undefined = undefined;
    let body: any = null;
    const contentType = c.req.header("content-type");

    if (method !== "GET" && method !== "HEAD") {
      try {
        // Always get raw body first
        rawBody = await c.req.text();

        // Then parse based on content type
        if (contentType?.includes("application/json")) {
          body = JSON.parse(rawBody);
        } else if (contentType?.includes("application/x-www-form-urlencoded")) {
          // Parse form data from raw body
          const formData = new URLSearchParams(rawBody);
          body = Object.fromEntries(formData.entries());
        } else {
          body = rawBody;
        }
      } catch (error) {
        logger.warn("Failed to parse callback request body", error as Error);
        body = rawBody;
      }
    }

    using result = await Network.HandleWebhook(c.env.CALLBACKS, token, {
      method,
      headers,
      params,
      body,
      rawBody,
    });

    // Return the result from the callback function
    if (result) {
      // @ts-ignore
      return c.json(result);
    } else {
      return new Response("OK", { status: 200 });
    }
  } catch (error) {
    if (isCallbackError(error)) {
      const statusMap: Record<CallbackErrorType, number> = {
        INVALID_TOKEN_FORMAT: 400,
        INVALID_TOKEN: 400,
        NOT_FOUND: 404,
        EXPIRED: 410,
        SUSPENDED: 503,
        UNINITIALIZED: 500,
      };

      // Extract error type (handles DO serialization)
      const errorType = getCallbackErrorType(error as Error);
      if (!errorType) {
        // Shouldn't happen, but fallback to 500
        return captureServerError(c, error, "CallbackError missing type");
      }

      const status = statusMap[errorType];

      // Log only for actual errors, not expected conditions
      if (errorType !== "NOT_FOUND" && errorType !== "EXPIRED") {
        logger.warn("Callback error", {
          errorType,
          errorName: (error as Error).name,
          message: (error as Error).message,
          ...(error as any).context,
        });
      }

      // Return a clean message without the "CallbackError: " prefix
      const message = (error as Error).message.replace(/^CallbackError: /, "");
      return new Response(message, { status });
    }

    // All other errors are server errors
    return captureServerError(c, error, "Error processing callback");
  }
});

export default webhook;
