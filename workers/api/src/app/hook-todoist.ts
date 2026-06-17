import { Hono } from "hono";
import superjson from "superjson";

import { createLogger } from "@plotday/worker-util";

import { createDb } from "../db";
import type { Bindings } from "../env";
import { isCallbackError, getCallbackErrorType } from "../errors";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import { disposeRpc } from "../utils/rpc";
import { captureServerError } from "../utils/error-capture";

const hookTodoist = new Hono<{ Bindings: Bindings }>();

/**
 * Receives Todoist webhook events.
 *
 * Todoist webhooks are configured ONCE at the app level (a single callback URL
 * in the App Console), so every authorized user's events arrive at this one
 * endpoint. Each payload carries `event_data.project_id`, which is the Plot
 * channel id for the connector instance that enabled that project — we route on
 * it the same way the Unipile (`/hook/messaging`) handler routes on account_id.
 *
 * Auth: Todoist signs each request with HMAC-SHA256 over the raw body using the
 * app's client secret (AUTH_TODOIST_SECRET), delivered in the
 * `X-Todoist-Hmac-SHA256` header. We never trust a request without a matching
 * signature — the connector itself can't verify it because the client secret is
 * a server-only env var, so verification has to live here.
 */
hookTodoist.post("/hook/todoist", async (c) => {
  const logger = createLogger({ route: "hook/todoist" });

  // Read the raw body BEFORE parsing — the HMAC is computed over the exact bytes
  // Todoist sent, so we must verify against the unparsed text.
  const rawBody = await c.req.text();
  const signature = c.req.header("x-todoist-hmac-sha256");
  if (!(await verifyTodoistSignature(c.env.AUTH_TODOIST_SECRET, rawBody, signature))) {
    logger.warn("Todoist webhook signature mismatch");
    return c.json({ ok: false }, 401);
  }

  let event: TodoistWebhookEvent;
  try {
    event = JSON.parse(rawBody) as TodoistWebhookEvent;
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }

  const eventName = event.event_name;
  const eventData = event.event_data;
  const projectId =
    eventData?.project_id != null ? String(eventData.project_id) : null;

  if (!eventName || !eventData || !projectId) {
    // Nothing we can route — ack so Todoist doesn't retry. (All subscribed
    // events — item:*/note:* — carry project_id; this guards malformed or
    // future event shapes.)
    logger.info("Todoist webhook missing event_name/event_data/project_id; acking", {
      event_name: eventName ?? null,
      has_event_data: !!eventData,
      has_project_id: !!projectId,
    });
    return c.json({ ok: true });
  }

  const ctx = c.executionCtx as unknown as { exports: ExecutionContext["exports"] };

  try {
    await dispatchTodoistEvent(c.env, ctx, projectId, eventName, eventData, logger);
  } catch (error) {
    return captureServerError(c, error, "Todoist webhook handler threw", {
      event_name: eventName,
      project_id: projectId,
    });
  }

  return c.json({ ok: true });
});

type TodoistWebhookEvent = {
  event_name?: string;
  user_id?: string;
  event_data?: { project_id?: string | number; [k: string]: unknown };
  [k: string]: unknown;
};

/**
 * Verify a Todoist webhook signature: base64(HMAC-SHA256(rawBody, clientSecret))
 * compared in constant time against the `X-Todoist-Hmac-SHA256` header.
 */
export async function verifyTodoistSignature(
  clientSecret: string | undefined,
  rawBody: string,
  signature: string | undefined,
): Promise<boolean> {
  if (!clientSecret || !signature) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(clientSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(rawBody),
  );
  const expected = btoa(String.fromCharCode(...new Uint8Array(signatureBytes)));
  return constantTimeEquals(signature, expected);
}

/**
 * Route a verified Todoist event to every connector instance that enabled this
 * project. A project shared across two Plot users yields one channel row each;
 * dispatching to both is correct — each connector saves the link under its own
 * user, and the globally-unique `todoist:task:<id>` source dedups them onto one
 * shared thread.
 */
async function dispatchTodoistEvent(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  projectId: string,
  eventName: string,
  eventData: Record<string, unknown>,
  logger: ReturnType<typeof createLogger>,
): Promise<void> {
  const db = createDb(env);
  let rows: Array<{ twist_instance_id: string }>;
  try {
    rows = await db
      .selectFrom("channel")
      .select("twist_instance_id")
      .where("channel_id", "=", projectId)
      .where("enabled", "=", true)
      .execute();
  } finally {
    await db.destroy();
  }

  if (rows.length === 0) {
    logger.info("No enabled channel for Todoist project; dropping event", {
      project_id: projectId,
      event_name: eventName,
    });
    return;
  }

  for (const row of rows) {
    const token = await loadConnectorCallback(
      env,
      row.twist_instance_id,
      `webhook_callback_${projectId}`,
    );
    if (!token) {
      // Connector hasn't finished onChannelEnabled yet (race), or was disabled.
      logger.warn("Todoist webhook callback not stored for channel; dropping", {
        project_id: projectId,
        twist_instance_id: row.twist_instance_id,
      });
      continue;
    }

    try {
      const result = await invokeWebhookCallback(env, ctx, token, {
        eventName,
        eventData,
      });
      disposeRpc(result);
    } catch (error) {
      if (isCallbackError(error)) {
        const errorType = getCallbackErrorType(error as Error);
        if (
          errorType === "NOT_FOUND" ||
          errorType === "EXPIRED" ||
          errorType === "INVALID_TOKEN" ||
          errorType === "INVALID_TOKEN_FORMAT"
        ) {
          // Connector uninstalled between delivery and processing — drop.
          logger.warn("Todoist webhook callback permanently unavailable", {
            project_id: projectId,
            twist_instance_id: row.twist_instance_id,
            error_type: errorType,
          });
          continue;
        }
      }
      // Unexpected (or retriable SUSPENDED) — surface to the route handler.
      throw error;
    }
  }
}

/**
 * Load the connector's stored webhook callback token from its root Storage DO.
 * The connector writes it via `this.set(key, value)` (superjson-serialised) to
 * the Storage DO named `${twistInstanceId}:` (empty tool path = root store).
 *
 * Mirrors the helper in hook-messaging.ts; kept local to avoid coupling the
 * Todoist route to the Unipile handler's internals.
 */
async function loadConnectorCallback(
  env: Bindings,
  twistInstanceId: string,
  key: string,
): Promise<string | null> {
  const storageId = env.STORAGE.idFromName(`${twistInstanceId}:`);
  const storageObj = env.STORAGE.get(storageId);
  const raw = await storageObj.get(key);
  if (!raw) return null;
  try {
    return superjson.parse<string>(raw);
  } catch {
    return raw;
  }
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export default hookTodoist;
