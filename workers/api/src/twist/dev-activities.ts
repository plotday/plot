import { sql, type Kysely } from "kysely";

import type { DB } from "../db-types";
import { withDb } from "../db";
import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";
import { BUILTIN_TWIST_PACKAGE_ID as PLOT_TWIST_PACKAGE_ID } from "../utils/limits";
import { notifyUserSyncByEnv } from "../app/sync/notify";

type LogThreadContext = {
  threadId: string;
  plotTwistInstanceId: string;
};

/**
 * Ensures the shared Logs thread exists for a twist deployment and returns
 * the context needed to append a note.
 *
 * Routing (who the thread files under, for whom):
 *   - Personal env: thread.topic = `priority:@plot.twist-dev:personal:<owner_user_id>`.
 *     The `priority:@plot.twist-dev:` prefix tells classify_thread_for_user to
 *     default the thread into each consumer's @plot.twist-dev priority when
 *     they have no explicit override. Only the owner sees the thread.
 *   - Non-personal env: thread.topic = `priority:@plot.twist-dev:publisher:<group_id>`.
 *     thread.groups is populated with the publisher group id so the peer-filing
 *     trigger runs classify_thread_for_user for every group member; the topic
 *     prefix then defaults each member's filing into their @plot.twist-dev
 *     priority.
 *
 * Returns null when the thread cannot be materialized (e.g. no Plot twist
 * installed for the thread owner, or no auto-maintained publisher group).
 */
async function ensureLogsThread(
  db: Kysely<DB>,
  twistPackageId: string,
  environment: TwistEnvironment | string
): Promise<LogThreadContext | null> {
  const twistRow = await db
    .selectFrom("twist")
    .select(["id", "user_id", "publisher_id", "name", "is_source"])
    .where("twist_package_id", "=", twistPackageId)
    .where("environment", "=", environment as any)
    .executeTakeFirst();

  if (!twistRow) return null;

  const kind = twistRow.is_source ? "connector" : "twist";
  const title = `${twistRow.name} ${kind} logs (${environment})`;

  let threadOwnerUserId: string;
  let groupId: string | null = null;
  let topic: string;

  if (environment === "personal") {
    if (!twistRow.user_id) return null;
    threadOwnerUserId = twistRow.user_id;
    topic = `priority:@plot.twist-dev:personal:${threadOwnerUserId}`;
  } else {
    if (twistRow.publisher_id === null || twistRow.publisher_id === undefined) {
      return null;
    }
    const publisher = await db
      .selectFrom("publisher")
      .select("created_by")
      .where("id", "=", twistRow.publisher_id)
      .executeTakeFirst();
    if (!publisher?.created_by) return null;
    threadOwnerUserId = publisher.created_by;

    const group = await db
      .selectFrom("group")
      .select("id")
      .where("auto_publisher_id", "=", twistRow.publisher_id)
      .where("auto_maintained", "=", true)
      .executeTakeFirst();
    if (!group?.id) return null;
    groupId = group.id;
    topic = `priority:@plot.twist-dev:publisher:${group.id}`;
  }

  const contactIds: string[] = [];
  if (groupId) {
    const memberRows = await db
      .selectFrom("group_member")
      .select("contact_id")
      .where("group_id", "=", groupId)
      .execute();
    for (const r of memberRows) contactIds.push(r.contact_id);
  } else {
    // Personal logs thread: contact set is just the owner's primary contact
    // so the peer-filing trigger has nothing extra to do (classify does
    // the filing on insert via the upsert path).
    const primary = await db
      .selectFrom("user_contact")
      .select("contact_id")
      .where("user_id", "=", threadOwnerUserId)
      .where("primary", "=", true)
      .where("linked", "=", true)
      .where("archived_at", "is", null)
      .executeTakeFirst();
    if (primary?.contact_id) contactIds.push(primary.contact_id);
  }

  const plotTwistInstance = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select("twist_instance.id")
    .where("twist_instance.owner_id", "=", threadOwnerUserId)
    .where("twist.twist_package_id", "=", PLOT_TWIST_PACKAGE_ID)
    .where("twist_instance.archived_at", "is", null)
    .executeTakeFirst();
  if (!plotTwistInstance) return null;

  const key = `logs:${twistPackageId}:${environment}`;

  const threadRow = await db
    .insertInto("thread")
    .values({
      key,
      title,
      created_by: threadOwnerUserId,
      updated_by: 0,
      topic,
      twist_id: twistRow.id,
      groups: sql`${groupId ? [groupId] : []}::uuid[]` as any,
      contacts: sql`${contactIds}::uuid[]` as any,
    })
    .onConflict((oc) =>
      oc
        .columns(["twist_id", "key"])
        // Match the full predicate of thread_twist_key_unique so Postgres
        // can infer the partial unique index as the conflict arbiter.
        .where("twist_id", "is not", null)
        .where("key", "is not", null)
        .where("archived_at", "is", null)
        .doUpdateSet({
          title,
          updated_by: 0,
          topic,
          groups: sql`${groupId ? [groupId] : []}::uuid[]` as any,
          contacts: sql`${contactIds}::uuid[]` as any,
        })
    )
    .returning("id")
    .executeTakeFirstOrThrow();

  // File the thread for everyone who should see it. For personal env that's
  // just the owner; for publisher env it's every group member. classify
  // resolves the priority:@plot.twist-dev: topic prefix into each consumer's
  // Twist Development priority.
  if (groupId) {
    await sql`
      INSERT INTO thread_priority (thread_id, user_id, priority_id)
      SELECT DISTINCT
        ${threadRow.id}::uuid,
        uc.user_id,
        classify_thread_for_user(uc.user_id, ${threadRow.id}::uuid)
      FROM group_member gm
      JOIN user_contact uc ON uc.contact_id = gm.contact_id
      WHERE gm.group_id = ${groupId}::uuid
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL
        AND classify_thread_for_user(uc.user_id, ${threadRow.id}::uuid) IS NOT NULL
      ON CONFLICT (thread_id, user_id) DO NOTHING
    `.execute(db);
  } else {
    // Personal: file for the single owner.
    await sql`
      INSERT INTO thread_priority (thread_id, user_id, priority_id)
      SELECT
        ${threadRow.id}::uuid,
        ${threadOwnerUserId}::uuid,
        classify_thread_for_user(${threadOwnerUserId}::uuid, ${threadRow.id}::uuid)
      WHERE classify_thread_for_user(${threadOwnerUserId}::uuid, ${threadRow.id}::uuid) IS NOT NULL
      ON CONFLICT (thread_id, user_id) DO NOTHING
    `.execute(db);
  }

  return {
    threadId: threadRow.id,
    plotTwistInstanceId: plotTwistInstance.id,
  };
}

async function notifyLogsThreadConsumers(
  env: Bindings,
  db: Kysely<DB>,
  threadId: string
): Promise<void> {
  const rows = await db
    .selectFrom("thread_priority")
    .select("user_id")
    .distinct()
    .where("thread_id", "=", threadId)
    .execute();
  await Promise.allSettled(rows.map((r) => notifyUserSyncByEnv(env, r.user_id)));
}

export async function addLogsNote(
  env: Bindings,
  twistPackageId: string,
  logs: LogMessage[]
): Promise<void> {
  const logger = createLogger({ twist_package_id: twistPackageId });

  let threadIdToNotify: string | null = null;
  try {
    await withDb(env, async (db) => {
      const environment = logs[0]?.environment || "unknown";
      const ctx = await ensureLogsThread(db, twistPackageId, environment);
      if (!ctx) return;

      const formatted = logs
        .map((log) => `[${log.severity.toUpperCase()}] ${log.message}`)
        .join("\n");
      const content = ["```", formatted, "```"].join("\n");

      await db
        .insertInto("note")
        .values({
          thread_id: ctx.threadId,
          author_id: ctx.plotTwistInstanceId,
          created_by: ctx.plotTwistInstanceId,
          content,
          updated_by: 0,
          sync_depth: 1,
        })
        .execute();
      threadIdToNotify = ctx.threadId;
    });
  } catch (error) {
    logger.error("Failed to add logs note", error as Error);
  }

  if (threadIdToNotify) {
    try {
      await withDb(env, (db) => notifyLogsThreadConsumers(env, db, threadIdToNotify!));
    } catch (error) {
      logger.error("Failed to broadcast logs note sync", error as Error);
    }
  }
}

export async function addUpgradeNote(
  env: Bindings,
  twistPackageId: string,
  environment: TwistEnvironment,
  version: string
): Promise<void> {
  const logger = createLogger({
    twist_package_id: twistPackageId,
    environment,
  });

  let threadIdToNotify: string | null = null;
  try {
    await withDb(env, async (db) => {
      const ctx = await ensureLogsThread(db, twistPackageId, environment);
      if (!ctx) return;

      await db
        .insertInto("note")
        .values({
          thread_id: ctx.threadId,
          author_id: ctx.plotTwistInstanceId,
          created_by: ctx.plotTwistInstanceId,
          content: `Upgraded to v${version}`,
          updated_by: 0,
          sync_depth: 1,
        })
        .execute();
      threadIdToNotify = ctx.threadId;
    });
  } catch (error) {
    logger.error("Failed to add upgrade note", error as Error);
  }

  if (threadIdToNotify) {
    try {
      await withDb(env, (db) => notifyLogsThreadConsumers(env, db, threadIdToNotify!));
    } catch (error) {
      logger.error("Failed to broadcast upgrade note sync", error as Error);
    }
  }
}
