/**
 * Daily sweep: permanently erase accounts whose 14-day deletion window has
 * elapsed (user.deletion_requested_at set by DELETE /account).
 *
 * Per user, in order:
 *   1. Remove every connection via the connector's removeAuth callback
 *      (clears stored auth tokens, channel access, connection rows) —
 *      same path as in-app disconnect and plan-downgrade trimming.
 *   2. Archive remaining twist instances via archiveAndDeleteTwist (runs
 *      deactivate callbacks, archives links/threads), then delete any
 *      Unipile-hosted accounts — same path as in-app uninstall.
 *   3. Delete the user's uploaded files from R2 (matched on the
 *      uploadedBy custom metadata set by POST /files).
 *   4. Delete the Clerk user (idempotent if already gone).
 *   5. Delete the DB user row — FK cascades erase all remaining data and
 *      make the sweep terminal/idempotent.
 *
 * Steps 1-4 are best-effort (logged + captured); step 5 always runs so a
 * partial failure can't leave the account half-alive past the window.
 */
import { createClerkClient } from "@clerk/backend";
import { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";

import { sql, withDb, type DB } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist/factory";
import {
  archiveAndDeleteTwist,
  removeIntegrationAccount,
} from "../twist/management";
import { deleteHostedAccountsForInstance } from "../twist/tools/unipile/account-cleanup";
import { BUILTIN_TWIST_PACKAGE_ID } from "../utils/limits";

const MAX_USERS_PER_RUN = 25;

export type PurgeCandidate = {
  id: string;
  clerk_id: string | null;
  email: string;
};

export async function findUsersToPurge(
  db: Kysely<DB>
): Promise<PurgeCandidate[]> {
  return await db
    .selectFrom("user")
    .select(["id", "clerk_id", "email"])
    .where("deletion_requested_at", "is not", null)
    .where("deletion_requested_at", "<", sql<Date>`now() - interval '14 days'`)
    .orderBy("deletion_requested_at", "asc")
    .limit(MAX_USERS_PER_RUN)
    .execute();
}

/** Minimal structural slice of R2Bucket used here (keeps tests dependency-free). */
export type FileBucket = {
  list(options: {
    prefix: string;
    cursor?: string;
    include: ["customMetadata"];
  }): Promise<
    | {
        objects: { key: string; customMetadata?: Record<string, string> }[];
        truncated: true;
        cursor: string;
      }
    | {
        objects: { key: string; customMetadata?: Record<string, string> }[];
        truncated: false;
      }
  >;
  delete(keys: string | string[]): Promise<void>;
};

export async function purgeUserFiles(
  bucket: FileBucket,
  userId: string
): Promise<number> {
  let cursor: string | undefined;
  let deleted = 0;
  do {
    const page = await bucket.list({
      prefix: "files/",
      cursor,
      include: ["customMetadata"],
    });
    const keys = page.objects
      .filter((o) => o.customMetadata?.uploadedBy === userId)
      .map((o) => o.key);
    if (keys.length > 0) {
      await bucket.delete(keys);
      deleted += keys.length;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}

export async function purgeDeletedAccounts(
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "purgeDeletedAccounts" });
  const postHog = new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
    before_send: exceptionFingerprintBeforeSend,
  });

  try {
    await withDb(env, async (db) => {
      const users = await findUsersToPurge(db);
      if (users.length === 0) return;
      logger.info("Purging deleted accounts", { count: users.length });

      for (const user of users) {
        await purgeUser(env, ctx, db, user, logger, postHog);
      }
    });
  } finally {
    ctx.waitUntil(postHog.shutdown());
  }
}

async function purgeUser(
  env: Bindings,
  ctx: ExecutionContext,
  db: Kysely<DB>,
  user: PurgeCandidate,
  logger: ReturnType<typeof createLogger>,
  postHog: PostHog
): Promise<void> {
  const capture = (error: Error, step: string) => {
    logger.error(`Account purge step failed: ${step}`, error, {
      user_id: user.id,
    });
    postHog.captureException(error, undefined, {
      operation: "purgeDeletedAccounts",
      step,
      user_id: user.id,
    });
  };

  // Same narrowed-ctx cast as refresh-channels.ts — the factory only needs
  // ctx.exports (+ waitUntil when present).
  const factory = twistFactory({ env, ctx: ctx as any, db });

  // 1. Connections → connector removeAuth (clears stored tokens + channels).
  const connections = await db
    .selectFrom("twist_instance_connection as tic")
    .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
    .select(["tic.twist_instance_id", "tic.provider", "tic.actor_id"])
    .where("tic.user_id", "=", user.id)
    .where("ti.archived_at", "is", null)
    .execute();
  for (const row of connections) {
    try {
      await removeIntegrationAccount({
        db,
        env,
        twistFactory: factory,
        twistInstanceId: row.twist_instance_id,
        provider: row.provider,
        actorId: row.actor_id,
      });
    } catch (error) {
      capture(error as Error, "removeIntegrationAccount");
    }
  }

  // 2. Remaining twist instances → uninstall flow (skip the built-in Plot
  // twist, which archiveAndDeleteTwist refuses; its rows cascade in step 5).
  const instances = await db
    .selectFrom("twist_instance as ti")
    .innerJoin("twist as t", "t.id", "ti.twist_id")
    .select(["ti.id", "t.is_source"])
    .where("ti.owner_id", "=", user.id)
    .where("ti.archived_at", "is", null)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .execute();
  for (const inst of instances) {
    try {
      await archiveAndDeleteTwist(db, inst.id, { twistFactory: factory });
      if (inst.is_source) {
        await deleteHostedAccountsForInstance(env, db, inst.id);
      }
    } catch (error) {
      capture(error as Error, "archiveAndDeleteTwist");
    }
  }

  // 3. Uploaded files in R2.
  try {
    const removed = await purgeUserFiles(
      env.FILES_BUCKET as unknown as FileBucket,
      user.id
    );
    if (removed > 0) {
      logger.info("Purged user files", { user_id: user.id, files: removed });
    }
  } catch (error) {
    capture(error as Error, "purgeUserFiles");
  }

  // 4. Clerk user (the user.deleted webhook may race us; both paths are
  // idempotent deletes by id).
  if (user.clerk_id) {
    try {
      const clerk = createClerkClient({ secretKey: env.CLERK_SECRET_KEY });
      await clerk.users.deleteUser(user.clerk_id);
    } catch (error) {
      const status = (error as { status?: number }).status;
      if (status !== 404) {
        capture(error as Error, "clerkDeleteUser");
      }
    }
  }

  // 5. DB row — cascades all remaining user data and ends eligibility.
  await db.deleteFrom("user").where("id", "=", user.id).execute();

  logger.info("Account permanently purged", { user_id: user.id });
}
