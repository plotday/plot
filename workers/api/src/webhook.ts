import { Hono } from "hono";

import { Network } from "./twist/tools/network";
import type { Bindings } from "./env";
import { verifyPubSubToken } from "./utils/pubsub";

const webhook = new Hono<{ Bindings: Bindings }>();

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
webhook.post("/hook/slack", async (c) => {
  try {
    const signature = c.req.header("x-slack-signature");
    const timestamp = c.req.header("x-slack-request-timestamp");

    if (!signature || !timestamp) {
      console.warn("Slack webhook missing signature or timestamp");
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
      console.warn("Slack webhook signature verification failed");
      return new Response("Unauthorized", { status: 401 });
    }

    // Parse body
    let body: any;
    try {
      body = JSON.parse(rawBody);
    } catch (error) {
      console.warn("Failed to parse Slack webhook body:", error);
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
    await Network.HandleSlackWebhook(c.env.CALLBACKS, {
      method: "POST",
      headers,
      params,
      body,
    });

    // Always return 200 OK to Slack (as per plan)
    return c.json({ ok: true });
  } catch (error) {
    console.error("Error processing Slack webhook:", error);
    // Still return 200 OK to prevent Slack from disabling the webhook
    return c.json({ ok: true });
  }
});

// Gmail webhook endpoint - handles Google Pub/Sub push notifications
webhook.post("/hook/gmail/:topicId", async (c) => {
  try {
    const authHeader = c.req.header("authorization");

    // Verify Pub/Sub JWT token
    const isValid = await verifyPubSubToken(authHeader, c.env.GCP_PROJECT_ID);
    if (!isValid) {
      console.warn("Gmail webhook missing or invalid authorization");
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
      console.warn("Failed to parse Gmail webhook body:", error);
      return new Response("Bad request", { status: 400 });
    }

    // Pub/Sub push messages have a specific format
    // https://cloud.google.com/pubsub/docs/push#receiving_messages
    const message = body.message;
    if (!message) {
      console.warn("Gmail webhook missing message field");
      return new Response("Bad request (missing message)", { status: 400 });
    }

    // Decode base64-encoded message data
    let decodedData: any = {};
    if (message.data) {
      try {
        const decoded = atob(message.data);
        decodedData = JSON.parse(decoded);
      } catch (error) {
        console.warn("Failed to decode Gmail webhook message data:", error);
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
    await Network.HandleGmailWebhook(
      c.env.CALLBACKS,
      callbackToken,
      webhookRequest
    );

    // Always return 200 OK to acknowledge message
    return c.json({ ok: true });
  } catch (error) {
    console.error("Error processing Gmail webhook:", error);
    // Return 500 to indicate failure, so Pub/Sub will retry
    return new Response("Internal server error", { status: 500 });
  }
});

// Webhook endpoint - handles all HTTP methods for webhook URLs
webhook.all(Network.PATH, async (c) => {
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
        console.warn("Failed to parse callback request body:", error);
        body = rawBody;
      }
    }

    const result = await Network.HandleWebhook(c.env.CALLBACKS, token, {
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
    console.error("Error processing callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

export default webhook;
