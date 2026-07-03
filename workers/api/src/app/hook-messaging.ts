import { Hono } from "hono";
import superjson from "superjson";

import { createLogger } from "@plotday/worker-util";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { isCallbackError, getCallbackErrorType } from "../errors";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import { disposeRpc } from "../utils/rpc";
import { notifyUserSyncByEnv } from "./sync/notify";
import { captureServerError } from "../utils/error-capture";
import { classifyEvent, type HostedWebhookEvent } from "./hook-messaging-classify";
import { verifyUnipileSignature } from "./hook-messaging-verify";

const hookMessaging = new Hono<{ Bindings: Bindings }>();

/**
 * Receives Unipile webhook events. One URL per workspace; events
 * differentiated by `event_type` in the body. Vendor naming stays
 * internal to this file — the public surface is "messaging" events.
 */
hookMessaging.post("/hook/messaging", async (c) => {
  const logger = createLogger({ route: "hook/messaging" });

  // Unipile v2 signs every delivery with HMAC SHA-256: header
  // `unipile-signature: t=<unix>,v0=<hmac-hex>` over `${t}.${rawBody}`, keyed on
  // the per-endpoint secret (UNIPILE_WEBHOOK_SECRET). Verify against the RAW
  // body — never parse-then-reserialize. See ./hook-messaging-verify.
  // https://developer.unipile.com/v2.0/docs/configure-a-webhook
  const signature = c.req.header("unipile-signature");
  const bodyText = await c.req.text();
  if (!(await verifyUnipileSignature(signature, bodyText, c.env.UNIPILE_WEBHOOK_SECRET))) {
    logger.warn("Unipile webhook signature verification failed", {
      have_signature: !!signature,
      header_names: Object.keys(c.req.header()),
    });
    // A delivery that carried a signature but failed verification is almost
    // never internet noise (scanners don't send `unipile-signature`) — it means
    // our stored UNIPILE_WEBHOOK_SECRET no longer matches the endpoint's signing
    // secret. That happens when the Unipile webhook is recreated (recreation
    // rotates the secret) but the deployed secret isn't re-synced
    // (scripts/sync-github-secrets). Every delivery then 401s and Unipile backs
    // off the endpoint, silently stranding ALL inbound messages for that
    // environment. Capture it so a secret drift pages instead of hiding.
    // Requests with no signature header are just noise — warn only, no capture.
    if (signature) {
      c.var.tracker.captureException(
        new Error(
          "Unipile webhook signature verification failed with a signature present " +
            "— UNIPILE_WEBHOOK_SECRET likely out of sync with the endpoint's " +
            "signing secret (re-run scripts/sync-github-secrets after any webhook recreation)."
        ),
        { path: c.req.path, method: c.req.method, route: "hook/messaging" }
      );
    }
    return c.json({ ok: false }, 401);
  }

  let event: HostedWebhookEvent;
  try {
    event = JSON.parse(bodyText) as HostedWebhookEvent;
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }

  // Log every incoming payload's top-level keys + the dispatch hints we
  // care about. Unipile mixes two payload shapes on this endpoint (the
  // hosted-auth notify_url callback uses `status`, while regular
  // workspace webhooks use `event_type`), and the field set has changed
  // across their API revisions, so visibility into what actually arrives
  // beats guessing.
  logger.info("hook/messaging received", {
    keys: Object.keys(event),
    type: event.type ?? null,
    event_type: event.event_type ?? null,
    status: event.status ?? null,
    account_id: event.account_id ?? event.AccountId ?? null,
  });

  const dispatch = classifyEvent(event);
  const ctx = c.executionCtx as unknown as { exports: ExecutionContext["exports"] };

  try {
    switch (dispatch) {
      case "account.connected":
        await handleAccountConnected(c.env, event, logger);
        break;
      case "account.needs_reauth":
        await handleAccountNeedsReauth(c.env, event, logger);
        break;
      case "messaging.new_message":
        await handleNewMessage(c.env, ctx, event, logger);
        break;
      case "users.invitation.received":
        await handleInvitationReceived(c.env, ctx, event, logger);
        break;
      case "users.new_relation":
        await handleNewRelation(c.env, ctx, event, logger);
        break;
      default:
        logger.info("Unhandled hosted-auth event", {
          event_type: event.event_type ?? null,
          status: event.status ?? null,
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

async function handleAccountConnected(
  env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  // The hosted-auth-link `name` parameter carries our state token (set by
  // GenerateHostedAuthUrl). Unipile echoes it on the notify_url callback.
  const state = (event.name as string | undefined) ?? null;
  const accountId =
    (event.account_id as string | undefined) ??
    (event.AccountId as string | undefined) ??
    null;
  if (!state || !accountId) {
    logger.warn("account.connected event missing state or account_id", {
      have_state: !!state,
      have_account_id: !!accountId,
    });
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
      accountType: (event.provider as string | undefined) ?? null,
      receivedAt: Date.now(),
    })
  );
  logger.info("account.connected recorded", { state, account_id: accountId });
}

async function handleAccountNeedsReauth(
  env: Bindings,
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id ?? event.AccountId ?? null;
  if (!accountId) return;
  logger.info("account needs reauth", {
    account_id: accountId,
    event_type: event.event_type,
  });

  // Look up which twist instance owns this account (channel_id = Unipile account_id)
  // and find the associated user so we can stamp needs_reauth_at.
  const db = createDb(env);
  try {
    const row = await db
      .selectFrom("channel")
      .innerJoin(
        "twist_instance_connection",
        "twist_instance_connection.twist_instance_id",
        "channel.twist_instance_id"
      )
      .select([
        "channel.twist_instance_id",
        "twist_instance_connection.user_id",
        "twist_instance_connection.provider",
      ])
      .where("channel.channel_id", "=", accountId)
      .executeTakeFirst();

    if (!row) {
      logger.warn("No connection found for account_id", {
        account_id: accountId,
      });
      return;
    }

    const now = new Date().toISOString();
    const result = await db
      .updateTable("twist_instance_connection")
      .set({ needs_reauth_at: now, recovery_pending: true })
      .where("twist_instance_id", "=", row.twist_instance_id)
      .where("user_id", "=", row.user_id)
      .where("provider", "=", row.provider)
      .where("needs_reauth_at", "is", null)
      .executeTakeFirst();

    if ((result.numUpdatedRows ?? 0n) > 0n) {
      // Notify the user's sync DO so the Flutter app picks up the reauth prompt.
      await notifyUserSyncByEnv(env, row.user_id);
      logger.info("Stamped needs_reauth_at for account", {
        account_id: accountId,
        twist_instance_id: row.twist_instance_id,
        user_id: row.user_id,
      });
    } else {
      logger.info("needs_reauth_at already set or row not found, skipping", {
        account_id: accountId,
      });
    }
  } finally {
    await db.destroy();
  }
}

/**
 * Load the connector's stored webhook callback token from the connector's
 * root Storage DO. The connector stores the token via `this.set(key, value)`
 * which writes to the Storage DO at name `${twistInstanceId}:` (empty tool
 * path — root-level store). The value is superjson-serialised.
 *
 * Returns null if the key is missing (connector not yet enabled / race with
 * onChannelEnabled).
 */
async function loadConnectorCallback(
  env: Bindings,
  twistInstanceId: string,
  key: string
): Promise<string | null> {
  // The connector's root Store DO name: `${twistInstanceId}:` (toolPath=[])
  const storageId = env.STORAGE.idFromName(`${twistInstanceId}:`);
  const storageObj = env.STORAGE.get(storageId);
  const raw = await storageObj.get(key);
  if (!raw) return null;
  try {
    // The Store tool serialises values with superjson. A Callback is a plain
    // string token; superjson wraps it as { json: "<token>", meta: ... }.
    const parsed = superjson.parse<string>(raw);
    return parsed;
  } catch {
    // Fallback: raw string (legacy or unserialised)
    return raw;
  }
}

async function handleNewMessage(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  const chatId = event.payload?.chat_id as string | undefined;
  const messageId = event.payload?.message_id as string | undefined;
  logger.info("new_message received", {
    account_id: accountId,
    chat_id: chatId,
    message_id: messageId,
  });

  if (!accountId) {
    logger.warn("new_message event missing account_id, dropping");
    return;
  }

  // Look up twist_instance_id for this Unipile account.
  const db = createDb(env);
  let twistInstanceId: string | undefined;
  try {
    const row = await db
      .selectFrom("channel")
      .select("twist_instance_id")
      .where("channel_id", "=", accountId)
      .executeTakeFirst();
    twistInstanceId = row?.twist_instance_id;
  } finally {
    await db.destroy();
  }

  if (!twistInstanceId) {
    logger.warn("No channel found for account_id, dropping new_message", {
      account_id: accountId,
    });
    return;
  }

  const callbackKey = `webhook_callback_${accountId}`;
  const token = await loadConnectorCallback(env, twistInstanceId, callbackKey);
  if (!token) {
    // Connector may not have finished onChannelEnabled yet (race condition).
    // The polling backstop will catch up.
    logger.warn(
      "Webhook callback not yet stored for account, dropping new_message",
      { account_id: accountId, twist_instance_id: twistInstanceId }
    );
    return;
  }

  try {
    const result = await invokeWebhookCallback(env, ctx, token, {
      kind: "message.received",
      chatId,
      messageId,
    });
    disposeRpc(result);
    logger.info("new_message callback invoked", {
      account_id: accountId,
      twist_instance_id: twistInstanceId,
    });
  } catch (error) {
    if (isCallbackError(error)) {
      const errorType = getCallbackErrorType(error as Error);
      if (
        errorType === "NOT_FOUND" ||
        errorType === "EXPIRED" ||
        errorType === "INVALID_TOKEN" ||
        errorType === "INVALID_TOKEN_FORMAT"
      ) {
        // Connector was uninstalled between webhook delivery and processing.
        logger.warn(
          "Webhook callback permanently unavailable for new_message",
          { account_id: accountId, error_type: errorType }
        );
        return;
      }
    }
    // Re-throw for unexpected errors — the route handler will capture them.
    throw error;
  }
}

async function handleInvitationReceived(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  const invitationId = event.payload?.invitation_id as string | undefined;
  logger.info("invitation received", {
    account_id: accountId,
    invitation_id: invitationId,
  });

  if (!accountId) {
    logger.warn("invitation.received event missing account_id, dropping");
    return;
  }

  // Look up twist_instance_id for this Unipile account.
  const db = createDb(env);
  let twistInstanceId: string | undefined;
  try {
    const row = await db
      .selectFrom("channel")
      .select("twist_instance_id")
      .where("channel_id", "=", accountId)
      .executeTakeFirst();
    twistInstanceId = row?.twist_instance_id;
  } finally {
    await db.destroy();
  }

  if (!twistInstanceId) {
    logger.warn(
      "No channel found for account_id, dropping invitation.received",
      { account_id: accountId }
    );
    return;
  }

  const callbackKey = `webhook_callback_${accountId}`;
  const token = await loadConnectorCallback(env, twistInstanceId, callbackKey);
  if (!token) {
    // Connector may not have finished onChannelEnabled yet (race condition).
    logger.warn(
      "Webhook callback not yet stored for account, dropping invitation.received",
      { account_id: accountId, twist_instance_id: twistInstanceId }
    );
    return;
  }

  try {
    const result = await invokeWebhookCallback(env, ctx, token, {
      kind: "invitation.received",
      invitationId,
    });
    disposeRpc(result);
    logger.info("invitation.received callback invoked", {
      account_id: accountId,
      twist_instance_id: twistInstanceId,
    });
  } catch (error) {
    if (isCallbackError(error)) {
      const errorType = getCallbackErrorType(error as Error);
      if (
        errorType === "NOT_FOUND" ||
        errorType === "EXPIRED" ||
        errorType === "INVALID_TOKEN" ||
        errorType === "INVALID_TOKEN_FORMAT"
      ) {
        logger.warn(
          "Webhook callback permanently unavailable for invitation.received",
          { account_id: accountId, error_type: errorType }
        );
        return;
      }
    }
    // Re-throw for unexpected errors — the route handler will capture them.
    throw error;
  }
}

async function handleNewRelation(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  // Unipile delivers the connected member's id under a few possible keys
  // depending on payload revision; check the documented one first.
  const profileId =
    (event.payload?.member_id as string | undefined) ??
    (event.payload?.user_id as string | undefined) ??
    (event.payload?.provider_id as string | undefined);
  logger.info("new_relation received", {
    account_id: accountId,
    profile_id: profileId,
  });

  if (!accountId) {
    logger.warn("new_relation event missing account_id, dropping");
    return;
  }
  if (!profileId) {
    logger.warn("new_relation event missing member id, dropping", {
      payload_keys: event.payload ? Object.keys(event.payload) : [],
    });
    return;
  }

  const db = createDb(env);
  let twistInstanceId: string | undefined;
  try {
    const row = await db
      .selectFrom("channel")
      .select("twist_instance_id")
      .where("channel_id", "=", accountId)
      .executeTakeFirst();
    twistInstanceId = row?.twist_instance_id;
  } finally {
    await db.destroy();
  }

  if (!twistInstanceId) {
    logger.warn("No channel found for account_id, dropping new_relation", {
      account_id: accountId,
    });
    return;
  }

  const callbackKey = `webhook_callback_${accountId}`;
  const token = await loadConnectorCallback(env, twistInstanceId, callbackKey);
  if (!token) {
    logger.warn(
      "Webhook callback not yet stored for account, dropping new_relation",
      { account_id: accountId, twist_instance_id: twistInstanceId }
    );
    return;
  }

  try {
    const result = await invokeWebhookCallback(env, ctx, token, {
      kind: "relation.new",
      profileId,
    });
    disposeRpc(result);
    logger.info("new_relation callback invoked", {
      account_id: accountId,
      twist_instance_id: twistInstanceId,
    });
  } catch (error) {
    if (isCallbackError(error)) {
      const errorType = getCallbackErrorType(error as Error);
      if (
        errorType === "NOT_FOUND" ||
        errorType === "EXPIRED" ||
        errorType === "INVALID_TOKEN" ||
        errorType === "INVALID_TOKEN_FORMAT"
      ) {
        logger.warn(
          "Webhook callback permanently unavailable for new_relation",
          { account_id: accountId, error_type: errorType }
        );
        return;
      }
    }
    throw error;
  }
}

export default hookMessaging;
