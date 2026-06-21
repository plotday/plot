import { createLogger } from "@plotday/worker-util";
import type { Kysely } from "kysely";

import { notifyUserSyncByEnv } from "../../app/sync/notify";
import type { DB } from "../../db-types";
import type { Bindings } from "../../env";
import { emitNeedsReauthEvent } from "../../utils/twist-events";

/**
 * Which code path detected the dead/invalid/missing credential and asked for
 * re-auth. Mirrors the allowed triggers on `connector_needs_reauth`.
 */
export type NeedsReauthTrigger =
  | "refresh_permanent"
  | "no_refresh_token"
  | "insufficient_scope"
  | "token_missing"
  | "connector_signal";

export type NeedsReauthDetails = {
  trigger: NeedsReauthTrigger;
  reason: string;
  oauthError?: string | null;
  status?: number | null;
};

/**
 * Flag a user's `twist_instance_connection` so the app prompts them to
 * re-authenticate, and push the change to their client so the tile flips from
 * "Syncing"/connected to "Reconnect" immediately.
 *
 * Shared by `Integrations.flagNeedsReauth` (OAuth refresh failures, connector
 * signals, insufficient-scope sweeps) and the Unipile messaging tool's
 * `assertAccount` (missing stored account credential). Keeping the write in one
 * place means every "this connection's credential is dead" path produces the
 * same durable state: `needs_reauth_at` (UI prompt) + `recovery_pending`
 * (so the next sync dispatch gets wipe-and-rewalk recovery semantics).
 *
 * Behaviour:
 * - Resolves `user_id` from the actor's contact row; orphan contacts (no
 *   linked user) are skipped.
 * - INSERT…ON CONFLICT so a connection with no existing
 *   `twist_instance_connection` row (lost saveAuth write) still gets flagged.
 * - Idempotent: the conflict UPDATE is gated on `needs_reauth_at IS NULL`, so a
 *   second call never overwrites the original flag time.
 * - On a *fresh* flag only: notifies the user's sync DO and (when `details` is
 *   given) emits the `connector_needs_reauth` PostHog event preserving the
 *   reason.
 * - Never throws — a failure here must not abort the caller's error path.
 */
export async function flagConnectionNeedsReauth(
  db: Kysely<DB>,
  env: Bindings,
  params: {
    twistInstanceId: string;
    provider: string;
    actorId: string;
    details?: NeedsReauthDetails;
  },
): Promise<void> {
  const { twistInstanceId, provider, actorId, details } = params;
  const logger = createLogger({ twist_instance_id: twistInstanceId });
  try {
    const reauthContact = await db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actorId)
      .executeTakeFirst();

    if (!reauthContact?.user_id) {
      logger.debug(
        `Skipped needs_reauth_at: actor ${actorId} has no linked user_id`,
        { provider, actor_id: actorId },
      );
      return;
    }

    const now = new Date().toISOString();
    const result = await db
      .insertInto("twist_instance_connection")
      .values({
        twist_instance_id: twistInstanceId,
        user_id: reauthContact.user_id,
        provider,
        actor_id: actorId,
        connected_at: now,
        needs_reauth_at: now,
        recovery_pending: true,
      })
      .onConflict((oc) =>
        oc
          .columns(["twist_instance_id", "user_id", "provider"])
          .doUpdateSet({ needs_reauth_at: now, recovery_pending: true })
          .where("twist_instance_connection.needs_reauth_at", "is", null),
      )
      .executeTakeFirst();

    if ((result.numInsertedOrUpdatedRows ?? 0n) > 0n) {
      await notifyUserSyncByEnv(env, reauthContact.user_id);
      if (details) {
        await emitNeedsReauthEvent({
          env,
          userId: reauthContact.user_id,
          twistInstanceId,
          provider,
          actorId,
          trigger: details.trigger,
          reason: details.reason,
          oauthError: details.oauthError ?? null,
          status: details.status ?? null,
        });
      }
    }
  } catch (dbError) {
    logger.warn(
      `Failed to set needs_reauth_at for ${provider} actor ${actorId}: ${
        (dbError as Error)?.message ?? String(dbError)
      }`,
      { provider, actor_id: actorId },
    );
  }
}
