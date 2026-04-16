import { sql, type Kysely } from "kysely";

import type { DB } from "../db-types";
import { withDb } from "../db";
import type { Bindings, LogMessage, TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";
import { BUILTIN_TWIST_PACKAGE_ID as PLOT_TWIST_PACKAGE_ID } from "../utils/limits";

type LogThreadContext = {
  threadId: string;
  plotTwistInstanceId: string;
};

/**
 * Ensures the shared Logs thread exists for a twist deployment and returns
 * the context needed to append a note.
 *
 * Routing (who the thread files under, for whom):
 *   - Personal env: thread.topic = `personal-twists:<owner_user_id>`. The
 *     activate_invited_user-installed priority_rule routes it into the
 *     owner's @plot.twist-dev priority. Only the owner sees the thread.
 *   - Non-personal env: thread is tagged with the publisher group id as its
 *     topic, so everyone in the publisher group sees it through their
 *     @plot.twist-dev rule. thread.groups is populated with the publisher
 *     group id, so the peer-filing trigger handles thread_priority for them.
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
    .select(["user_id", "publisher_id"])
    .where("twist_package_id", "=", twistPackageId)
    .where("environment", "=", environment as any)
    .executeTakeFirst();

  if (!twistRow) return null;

  let threadOwnerUserId: string;
  let groupId: string | null = null;
  let topic: string;

  if (environment === "personal") {
    if (!twistRow.user_id) return null;
    threadOwnerUserId = twistRow.user_id;
    topic = `personal-twists:${threadOwnerUserId}`;
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
    topic = group.id;
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
      title: `Logs (${environment})`,
      created_by: threadOwnerUserId,
      updated_by: 0,
      topic,
      groups: sql`${groupId ? [groupId] : []}::uuid[]` as any,
      contacts: sql`${contactIds}::uuid[]` as any,
    })
    .onConflict((oc) =>
      oc.columns(["created_by", "key"]).doUpdateSet({
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
  // picks up the priority_rule that matches thread.topic.
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

export async function addLogsNote(
  env: Bindings,
  twistPackageId: string,
  logs: LogMessage[]
): Promise<void> {
  const logger = createLogger({ twist_package_id: twistPackageId });

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
    });
  } catch (error) {
    logger.error("Failed to add logs note", error as Error);
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
    });
  } catch (error) {
    logger.error("Failed to add upgrade note", error as Error);
  }
}
