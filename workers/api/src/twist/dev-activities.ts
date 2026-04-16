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
 * the context needed to append a note. The thread is tagged with the
 * publisher topic (non-personal) or the per-user personal-twist topic so the
 * contact_topics priority_rule routes it into each member's @plot.twist-dev
 * priority.
 *
 * Returns null when the thread cannot be materialized (e.g. no Plot twist
 * installed for the thread owner, or no auto-maintained topic yet).
 */
async function ensureLogsThread(
  db: Kysely<DB>,
  twistPackageId: string,
  environment: TwistEnvironment | string
): Promise<LogThreadContext | null> {
  // Resolve the twist row for this package + environment to find the owner.
  const twistRow = await db
    .selectFrom("twist")
    .select(["user_id", "publisher_id"])
    .where("twist_package_id", "=", twistPackageId)
    .where("environment", "=", environment as any)
    .executeTakeFirst();

  if (!twistRow) return null;

  let threadOwnerUserId: string;
  let topicId: string | null = null;

  if (environment === "personal") {
    if (!twistRow.user_id) return null;
    threadOwnerUserId = twistRow.user_id;

    const topic = await db
      .selectFrom("topic")
      .select("id")
      .where("auto_personal_twist_user_id", "=", threadOwnerUserId)
      .where("auto_maintained", "=", true)
      .executeTakeFirst();
    topicId = topic?.id ?? null;
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

    const topic = await db
      .selectFrom("topic")
      .select("id")
      .where("auto_publisher_id", "=", twistRow.publisher_id)
      .where("auto_maintained", "=", true)
      .executeTakeFirst();
    topicId = topic?.id ?? null;
  }

  if (!topicId) return null;

  const memberRows = await db
    .selectFrom("topic_member")
    .select("contact_id")
    .where("topic_id", "=", topicId)
    .execute();
  const contactIds = memberRows.map((r) => r.contact_id);

  // Need the owner's Plot twist_instance to attribute the log note as coming
  // from the Plot runtime.
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

  // Upsert the thread. created_by is the owner user so file_thread_priority_peers
  // (which only runs for user-authored threads) files peer topic members.
  const threadRow = await db
    .insertInto("thread")
    .values({
      key,
      title: `Logs (${environment})`,
      created_by: threadOwnerUserId,
      updated_by: 0,
      topics: sql`${[topicId]}::uuid[]` as any,
      contacts: sql`${contactIds}::uuid[]` as any,
    })
    .onConflict((oc) =>
      oc.columns(["created_by", "key"]).doUpdateSet({
        updated_by: 0,
        topics: sql`${[topicId]}::uuid[]` as any,
        contacts: sql`${contactIds}::uuid[]` as any,
      })
    )
    .returning("id")
    .executeTakeFirstOrThrow();

  // Explicitly file the thread into each topic member's @plot.twist-dev
  // priority via classify_thread_for_user. The peer trigger skips the author
  // and only runs on INSERT, so we file everyone here to cover both fresh and
  // repeat deployments.
  await sql`
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT DISTINCT
      ${threadRow.id}::uuid,
      uc.user_id,
      classify_thread_for_user(uc.user_id, ${threadRow.id}::uuid)
    FROM topic_member tm
    JOIN user_contact uc ON uc.contact_id = tm.contact_id
    WHERE tm.topic_id = ${topicId}::uuid
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
      AND classify_thread_for_user(uc.user_id, ${threadRow.id}::uuid) IS NOT NULL
    ON CONFLICT (thread_id, user_id) DO NOTHING
  `.execute(db);

  return {
    threadId: threadRow.id,
    plotTwistInstanceId: plotTwistInstance.id,
  };
}

/**
 * Adds log output to the shared Logs thread for a twist deployment.
 */
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

/**
 * Adds an upgrade marker note to the Logs thread for a twist deployment.
 */
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
