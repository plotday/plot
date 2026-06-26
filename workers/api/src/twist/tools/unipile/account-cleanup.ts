import { createLogger } from "@plotday/worker-util";
import type { Kysely } from "kysely";

import type { DB } from "../../../db";
import type { Bindings } from "../../../env";
import { PROVIDER_CONFIGS } from "../../../provider";
import { UnipileApiError, UnipileClient } from "./client";
import type { UnipileAccount } from "./types";

/** Minimal tracker shape so callers can pass `c.var.tracker` without coupling. */
type Tracker = { captureException: (error: unknown) => void };

/**
 * Delete one Unipile account, best-effort. Cleanup must never block a teardown
 * or an auth completion, so this NEVER throws: a 404 means the account is
 * already gone (success); any other failure is logged and reported.
 */
export async function deleteUnipileAccount(
  env: Bindings,
  accountId: string,
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    account_id: accountId,
  });
  try {
    await new UnipileClient(env).deleteAccount(accountId);
    logger.info("Deleted Unipile account");
  } catch (error) {
    if (error instanceof UnipileApiError && error.status === 404) {
      logger.info("Unipile account already gone (404)");
      return;
    }
    logger.error("Failed to delete Unipile account", error as Error);
    opts?.tracker?.captureException(error);
  }
}

/**
 * Pure decision logic for the connect-time orphan sweep. Given every Unipile
 * account (each reduced to `{ id, identity }`), the account just connected, its
 * LinkedIn identity, and the set of account ids a live Plot connection still
 * references, return the ids to delete.
 *
 * An account is an orphan when it belongs to the SAME LinkedIn identity, is not
 * the account just connected, and is not referenced by any live connection
 * (the reference guard protects the rare case of two Plot users on one LinkedIn
 * login). A blank `identityId` selects nothing.
 */
export function selectOrphanAccountIds(
  accounts: Array<{ id: string; identity: string | null }>,
  newAccountId: string,
  identityId: string,
  referencedIds: Set<string>
): string[] {
  if (!identityId) return [];
  return accounts
    .filter(
      (a) =>
        a.id !== newAccountId &&
        a.identity === identityId &&
        !referencedIds.has(a.id)
    )
    .map((a) => a.id);
}

/**
 * Resolve a Unipile account's provider identity (member id). In v2 this is the
 * account's `user_id`, present directly on the list payload.
 */
function accountIdentity(account: UnipileAccount): string | null {
  return account.user_id ?? null;
}

/**
 * Of the given Unipile account ids, which are still referenced by a live Plot
 * connection — an ENABLED `channel` row under a NON-archived `twist_instance`
 * (channel_id == account_id for hosted connectors). Since v2 scopes Unipile
 * accounts per environment (see `sweepOrphanAccountsForIdentity`), this local DB
 * is the authoritative reference for everything in THIS environment's workspace.
 */
async function referencedAccountIds(
  db: Kysely<DB>,
  accountIds: string[]
): Promise<Set<string>> {
  if (accountIds.length === 0) return new Set();
  const rows = await db
    .selectFrom("channel")
    .innerJoin("twist_instance", "twist_instance.id", "channel.twist_instance_id")
    .select("channel.channel_id")
    .where("channel.channel_id", "in", accountIds)
    .where("channel.enabled", "=", true)
    .where("twist_instance.archived_at", "is", null)
    .execute();
  return new Set(rows.map((r) => r.channel_id));
}

/**
 * Connect-time orphan sweep (Flow B). After a hosted account finishes auth,
 * delete every OTHER Unipile account for the same LinkedIn identity that no
 * live Plot connection references. Best-effort: never throws.
 *
 * Environment isolation: in v2 each Plot environment has its own Unipile API
 * key, so `listAccounts()` returns only THIS environment's accounts. That makes
 * the local Plot DB the complete reference for what's in use here, so an
 * unreferenced same-identity account is safe to delete. Under v1's shared
 * workspace this sweep could reach the OTHER environment's accounts — a dev
 * reconnect could delete a live prod account (the local DB has no reference to
 * it) and vice versa; v2's per-environment keys remove that hazard. The
 * reference guard below stays for the genuine same-environment case: two
 * distinct Plot users on one LinkedIn login.
 */
export async function sweepOrphanAccountsForIdentity(
  env: Bindings,
  db: Kysely<DB>,
  params: { newAccountId: string; identityId: string },
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    new_account_id: params.newAccountId,
  });
  if (!params.identityId || params.identityId === params.newAccountId) return;

  let accounts: UnipileAccount[];
  try {
    accounts = await new UnipileClient(env).listAccounts();
  } catch (error) {
    logger.error("Orphan sweep: listAccounts failed", error as Error);
    opts?.tracker?.captureException(error);
    return;
  }

  const reduced = accounts.map((a) => ({ id: a.id, identity: accountIdentity(a) }));

  const sameIdentity = reduced
    .filter((a) => a.id !== params.newAccountId && a.identity === params.identityId)
    .map((a) => a.id);
  const referenced = await referencedAccountIds(db, sameIdentity);
  const toDelete = selectOrphanAccountIds(
    reduced,
    params.newAccountId,
    params.identityId,
    referenced
  );

  if (toDelete.length === 0) return;
  logger.info("Orphan sweep: deleting stale Unipile accounts", {
    count: toDelete.length,
  });
  for (const id of toDelete) {
    await deleteUnipileAccount(env, id, opts);
  }
}

/**
 * Delete every hosted (Unipile) account belonging to a removed connector
 * instance (Flow C). For hosted connectors the `channel.channel_id` IS the
 * Unipile account id. Runs after the instance is soft-archived, so the channel
 * rows and KV config still exist. Best-effort: never throws.
 */
export async function deleteHostedAccountsForInstance(
  env: Bindings,
  db: Kysely<DB>,
  twistInstanceId: string,
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    twist_instance_id: twistInstanceId,
  });

  const info = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select(["twist.twist_package_id as twistPackageId", "twist.version"])
    .where("twist_instance.id", "=", twistInstanceId)
    .executeTakeFirst();
  if (!info?.twistPackageId || !info.version) return;

  const raw = await env.TWIST_CONFIG.get(`${info.twistPackageId}:${info.version}`);
  if (!raw) return;
  let providers: Array<{ provider: string }> = [];
  try {
    providers = JSON.parse(raw).providers ?? [];
  } catch {
    return;
  }
  const hasHosted = providers.some(
    (p) =>
      PROVIDER_CONFIGS[p.provider as keyof typeof PROVIDER_CONFIGS]?.authMode ===
      "hosted"
  );
  if (!hasHosted) return;

  const channels = await db
    .selectFrom("channel")
    .select("channel_id")
    .where("twist_instance_id", "=", twistInstanceId)
    .execute();
  if (channels.length === 0) return;

  logger.info("Connector removed: deleting hosted Unipile accounts", {
    count: channels.length,
  });
  for (const ch of channels) {
    await deleteUnipileAccount(env, ch.channel_id, opts);
  }
}
