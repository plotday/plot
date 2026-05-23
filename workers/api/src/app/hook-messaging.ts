import { Hono } from "hono";

import { createLogger } from "@plotday/worker-util";
import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";

const hookMessaging = new Hono<{ Bindings: Bindings }>();

/**
 * Receives Unipile webhook events. One URL per workspace; events
 * differentiated by `event_type` in the body. Vendor naming stays
 * internal to this file — the public surface is "messaging" events.
 */
hookMessaging.post("/hook/messaging", async (c) => {
  const logger = createLogger({ route: "hook/messaging" });

  const signature = c.req.header("x-unipile-signature");
  const bodyText = await c.req.text();
  if (
    !signature ||
    !(await verifySignature(bodyText, signature, c.env.UNIPILE_WEBHOOK_SECRET))
  ) {
    logger.warn("Hosted-auth webhook signature mismatch");
    return c.json({ ok: false }, 401);
  }

  let event: HostedWebhookEvent;
  try {
    event = JSON.parse(bodyText) as HostedWebhookEvent;
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }

  try {
    switch (event.event_type) {
      case "account.connected":
        await handleAccountConnected(c.env, event, logger);
        break;
      case "account.disconnected":
      case "account.error":
      case "account.credentials":
        await handleAccountNeedsReauth(c.env, event, logger);
        break;
      case "messaging.new_message":
        await handleNewMessage(c.env, event, logger);
        break;
      case "users.invitation.received":
        await handleInvitationReceived(c.env, event, logger);
        break;
      default:
        logger.info("Unhandled hosted-auth event type", {
          event_type: event.event_type,
        });
    }
  } catch (error) {
    return captureServerError(c, error, "Hosted-auth webhook handler threw", {
      event_type: event.event_type,
      account_id: event.account_id,
    });
  }
  return c.json({ ok: true });
});

type HostedWebhookEvent = {
  event_type: string;
  account_id?: string;
  payload?: Record<string, unknown>;
  [k: string]: unknown;
};

async function verifySignature(
  body: string,
  signatureHeader: string,
  secret: string
): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body)
  );
  const expected = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  if (expected.length !== signatureHeader.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ signatureHeader.charCodeAt(i);
  }
  return diff === 0;
}

async function handleAccountConnected(
  env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  // The hosted-auth-link `name` parameter carries our state token (set by
  // GenerateHostedAuthUrl). Unipile echoes it on account.connected.
  const state = (event.name as string | undefined) ?? null;
  const accountId = event.account_id;
  if (!state || !accountId) {
    logger.warn("account.connected event missing state or account_id");
    return;
  }
  const storageObj = env.STORAGE.get(env.STORAGE.idFromName("auth"));
  // Pending state was written by GenerateHostedAuthUrl as superjson.stringify(...).
  // We don't need to read it here — we just need to write the result so the
  // /auth completion path can pair it.
  await storageObj.set(
    `hosted_auth_result:${state}`,
    JSON.stringify({
      accountId,
      accountType: (event.provider as string | undefined) ?? "LINKEDIN",
      receivedAt: Date.now(),
    })
  );
  logger.info("account.connected recorded", { state, account_id: accountId });
}

async function handleAccountNeedsReauth(
  _env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  if (!accountId) return;
  logger.info("account needs reauth", {
    account_id: accountId,
    event_type: event.event_type,
  });
  // Wired in Task 4.3: look up twist_instance_connection by access_token,
  // stamp needs_reauth_at = now(), recovery_pending = true.
}

async function handleNewMessage(
  _env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  logger.info("new_message received", { account_id: event.account_id });
  // Wired in Task 4.3: invoke the connector's stored webhook callback with
  // { kind: "message.received", chatId, messageId }.
}

async function handleInvitationReceived(
  _env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  logger.info("invitation received", { account_id: event.account_id });
  // Wired in Task 4.3: invoke the connector's stored webhook callback with
  // { kind: "invitation.received", invitationId }.
}

export default hookMessaging;
