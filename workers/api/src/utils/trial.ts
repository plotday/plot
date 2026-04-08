import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { PLAN_LIMITS } from "./limits";
import { createLogger } from "@plotday/worker-util";

/**
 * Get names of personal connections that exceed the free plan limit.
 * Ordered by connected_at desc (most recent first) — the ones that would be
 * removed on downgrade.
 */
export async function getExcessConnectionNames(
  db: Kysely<DB>,
  userId: string
): Promise<{ twistName: string; provider: string }[]> {
  const excess = await db
    .selectFrom("priority_twist_connection as ptc")
    .innerJoin("priority_twist as pt", "pt.id", "ptc.priority_twist_id")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .leftJoin("priority as p", "p.id", "pt.priority_id")
    .select(["t.name as twist_name", "ptc.provider"])
    .where("ptc.user_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .where((eb) =>
      eb.or([
        eb("pt.priority_id", "is", null),
        eb("p.organization_id", "is", null),
      ])
    )
    .orderBy("ptc.connected_at", "desc")
    .offset(PLAN_LIMITS.free.connections)
    .execute();

  return excess.map((r) => ({
    twistName: r.twist_name ?? "Unknown",
    provider: r.provider,
  }));
}

/**
 * Get names of personal non-source twists that exceed the free plan limit.
 * Ordered by created_at desc (most recent first) — the ones that would be
 * archived on downgrade.
 */
export async function getExcessTwistNames(
  db: Kysely<DB>,
  userId: string
): Promise<string[]> {
  const excess = await db
    .selectFrom("priority_twist as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .leftJoin("priority as p", "p.id", "pt.priority_id")
    .select("t.name")
    .where("pt.owner_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where((eb) =>
      eb.or([
        eb("pt.priority_id", "is", null),
        eb("p.organization_id", "is", null),
      ])
    )
    .orderBy("pt.created_at", "desc")
    .offset(PLAN_LIMITS.free.twists)
    .execute();

  return excess.map((r) => r.name ?? "Unknown");
}

/**
 * Build markdown content for a trial reminder note.
 */
export function buildReminderContent(
  daysLeft: number,
  excessConnections: { twistName: string; provider: string }[],
  excessTwists: string[],
  siteRoot: string
): string {
  const dayWord = daysLeft === 1 ? "day" : "days";
  let content = `Your free Core trial ends in **${daysLeft} ${dayWord}**. Upgrade to keep all your connections and twists.`;

  const lostItems: string[] = [];
  for (const conn of excessConnections) {
    lostItems.push(`${conn.twistName} (${conn.provider})`);
  }
  for (const twist of excessTwists) {
    lostItems.push(`${twist} twist`);
  }

  if (lostItems.length > 0) {
    content += "\n\n**You'll lose access to:**\n";
    content += lostItems.map((item) => `- ${item}`).join("\n");
  }

  content += `\n\n[Upgrade now →](${siteRoot}/upgrade)`;
  return content;
}

/**
 * Insert a note in the trial thread with Tag.todo for the user.
 * Uses `key` on the note for idempotency.
 * If `addTodo` is true, adds a Tag.todo (tag_id=1) note_tag for the user's contact.
 */
export async function addTrialNote(
  db: Kysely<DB>,
  threadId: string,
  userId: string,
  content: string,
  key: string,
  addTodo: boolean
): Promise<void> {
  // Look up user's primary contact for author_id
  const contact = await db
    .selectFrom("contact")
    .select("id")
    .where("user_id", "=", userId)
    .where("primary", "=", true)
    .executeTakeFirst();

  const authorId = contact?.id ?? userId;

  // Insert note with key for idempotency
  const note = await db
    .insertInto("note")
    .values({
      thread_id: threadId,
      content,
      created_by: userId,
      author_id: authorId,
      key,
    })
    .onConflict((oc) => oc.columns(["thread_id", "key"]).doNothing())
    .returning("id")
    .executeTakeFirst();

  if (!note) return; // Already exists (idempotent)

  if (addTodo && contact) {
    // Add Tag.todo (tag_id = 1) for the user's contact
    await db
      .insertInto("note_tag")
      .values({
        note_id: note.id,
        tag_id: 1, // Tag.todo
        actor_id: contact.id,
        updated_by: 0,
      })
      .onConflict((oc) =>
        oc.columns(["actor_id", "note_id", "tag_id"]).doNothing()
      )
      .execute();
  }
}

/**
 * Archive (complete) all todo tags on reminder notes in the trial thread.
 */
export async function completeTrialTodos(
  db: Kysely<DB>,
  threadId: string
): Promise<void> {
  // Find reminder notes by key pattern
  const reminderNotes = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", threadId)
    .where("key", "in", ["reminder-7day", "reminder-2day"])
    .execute();

  for (const note of reminderNotes) {
    await db
      .updateTable("note_tag")
      .set({ archived_at: sql`now()` })
      .where("note_id", "=", note.id)
      .where("tag_id", "=", 1) // Tag.todo
      .where("archived_at", "is", null)
      .execute();
  }
}

/**
 * Find the trial thread for a user in the @plot.app priority.
 */
async function findTrialThread(
  db: Kysely<DB>
): Promise<{ threadId: string; priorityId: string } | null> {
  const plotAppPriority = await db
    .selectFrom("priority")
    .select("id")
    .where("key", "=", "@plot.app")
    .executeTakeFirst();

  if (!plotAppPriority) return null;

  const thread = await db
    .selectFrom("thread")
    .select("id")
    .where("priority_id", "=", plotAppPriority.id)
    .where("key", "=", "core-trial")
    .executeTakeFirst();

  if (!thread) return null;

  return { threadId: thread.id, priorityId: plotAppPriority.id };
}

/**
 * Handle a trial user upgrading to a paid plan.
 * Adds a celebration note, completes outstanding todos, and cancels reminders.
 */
export async function handleTrialUpgrade(
  db: Kysely<DB>,
  env: Bindings,
  userId: string
): Promise<void> {
  const logger = createLogger({ operation: "handleTrialUpgrade", user_id: userId });

  const trial = await findTrialThread(db);
  if (!trial) {
    logger.warn("Trial thread not found for upgrade celebration", { user_id: userId });
    return;
  }

  // Add celebration note
  await addTrialNote(
    db,
    trial.threadId,
    userId,
    "You upgraded! Thanks for choosing Plot. All your connections and twists are yours to keep.",
    "upgraded",
    false
  );

  // Complete outstanding todo tags
  await completeTrialTodos(db, trial.threadId);

  // Cancel TrialReminder DO
  try {
    const trialReminderId = env.TRIAL_REMINDER.idFromName(userId);
    const trialReminderDO = env.TRIAL_REMINDER.get(trialReminderId);
    await trialReminderDO.fetch(
      new Request("http://do/cancel", { method: "POST" })
    );
  } catch (error) {
    logger.error("Failed to cancel trial reminder DO", error as Error, {
      user_id: userId,
    });
  }

  // Notify sync for the @plot.app priority
  try {
    const syncNotifyId = env.SYNC_NOTIFY.idFromName(trial.priorityId);
    const syncNotifyDO = env.SYNC_NOTIFY.get(syncNotifyId);
    await syncNotifyDO.fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: trial.priorityId }),
      })
    );
  } catch (error) {
    logger.error("Failed to notify sync after trial upgrade", error as Error);
  }

  logger.info("Handled trial upgrade", { user_id: userId });
}

/**
 * Expire a user's reverse trial — downgrade to free and archive excess.
 * Called by the TrialReminder DO alarm and by the cron fallback sweep.
 */
export async function expireTrial(
  db: Kysely<DB>,
  env: Bindings,
  userId: string,
  stripeCustomerId: string | null
): Promise<void> {
  const logger = createLogger({ operation: "expireTrial", user_id: userId });

  // Verify user is still on trial
  const sub = await db
    .selectFrom("user_subscription")
    .select(["plan", "trial_ends_at"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  if (!sub || sub.plan !== "core" || !sub.trial_ends_at) {
    logger.info("User not on trial, skipping expiry", { user_id: userId });
    return;
  }

  if (new Date(sub.trial_ends_at) > new Date()) {
    logger.info("Trial not yet expired, skipping", { user_id: userId });
    return;
  }

  // Get names of what they'll lose before downgrading
  const excessConnections = await getExcessConnectionNames(db, userId);
  const excessTwists = await getExcessTwistNames(db, userId);

  // Downgrade to free
  await db
    .updateTable("user_subscription")
    .set({ plan: "free" })
    .where("user_id", "=", userId)
    .execute();

  // Enforce limits (archive excess twists, delete excess connections)
  if (stripeCustomerId) {
    // Reuse the existing enforceDowngradeLimits logic inline since it's in stripe.ts
    // and requires a logger. We replicate the essential parts here.
    const limits = PLAN_LIMITS.free;

    // Trim excess connections
    if (limits.connections !== Infinity) {
      const excess = await db
        .selectFrom("priority_twist_connection as ptc")
        .innerJoin("priority_twist as pt", "pt.id", "ptc.priority_twist_id")
        .leftJoin("priority as p", "p.id", "pt.priority_id")
        .select(["ptc.priority_twist_id", "ptc.user_id", "ptc.provider"])
        .where("ptc.user_id", "=", userId)
        .where((eb) =>
          eb.or([
            eb("pt.priority_id", "is", null),
            eb("p.organization_id", "is", null),
          ])
        )
        .orderBy("ptc.connected_at", "desc")
        .offset(limits.connections)
        .execute();

      for (const row of excess) {
        await db
          .deleteFrom("priority_twist_connection")
          .where("priority_twist_id", "=", row.priority_twist_id)
          .where("user_id", "=", row.user_id)
          .where("provider", "=", row.provider)
          .execute();
      }

      if (excess.length > 0) {
        logger.info("Trimmed excess connections on trial expiry", {
          user_id: userId,
          removed: excess.length,
        });
      }
    }

    // Archive excess twists
    if (limits.twists !== Infinity) {
      const excessPts = await db
        .selectFrom("priority_twist as pt")
        .innerJoin("twist as t", "t.id", "pt.twist_id")
        .leftJoin("priority as p", "p.id", "pt.priority_id")
        .select("pt.id")
        .where("pt.owner_id", "=", userId)
        .where("pt.archived_at", "is", null)
        .where("t.is_source", "=", false)
        .where((eb) =>
          eb.or([
            eb("pt.priority_id", "is", null),
            eb("p.organization_id", "is", null),
          ])
        )
        .orderBy("pt.created_at", "desc")
        .offset(limits.twists)
        .execute();

      for (const row of excessPts) {
        await db
          .updateTable("priority_twist")
          .set({ archived_at: new Date().toISOString() })
          .where("id", "=", row.id)
          .execute();
      }

      if (excessPts.length > 0) {
        logger.info("Archived excess twists on trial expiry", {
          user_id: userId,
          archived: excessPts.length,
        });
      }
    }
  }

  // Add final note to trial thread
  const trial = await findTrialThread(db);
  if (trial) {
    const siteRoot = env.SITE_ROOT || "https://plot.day";

    let content =
      "Your Core trial has ended and you're now on the Free plan.";

    const lostItems: string[] = [];
    for (const conn of excessConnections) {
      lostItems.push(`${conn.twistName} (${conn.provider})`);
    }
    for (const twist of excessTwists) {
      lostItems.push(`${twist} twist`);
    }

    if (lostItems.length > 0) {
      content += " We've archived the following to fit the free limits:\n";
      content += lostItems.map((item) => `- ${item}`).join("\n");
      content += "\n\n";
    } else {
      content += " ";
    }

    content += `You can upgrade anytime to unlock more connections and twists. [Upgrade →](${siteRoot}/upgrade)`;

    await addTrialNote(db, trial.threadId, userId, content, "expired", false);

    // Complete any remaining todos
    await completeTrialTodos(db, trial.threadId);

    // Notify sync for @plot.app priority
    try {
      const syncNotifyId = env.SYNC_NOTIFY.idFromName(trial.priorityId);
      const syncNotifyDO = env.SYNC_NOTIFY.get(syncNotifyId);
      await syncNotifyDO.fetch(
        new Request("http://do/notify", {
          method: "POST",
          body: JSON.stringify({ id: trial.priorityId }),
        })
      );
    } catch (error) {
      logger.error("Failed to notify sync after trial expiry", error as Error);
    }
  }

  // Notify user sync so the app picks up the plan change
  try {
    await db
      .insertInto("user_sync")
      .values({
        user_id: userId,
        entity: "subscription",
        last_update_at: sql`now()`,
      })
      .onConflict((oc) =>
        oc.columns(["user_id", "entity"]).doUpdateSet({
          last_update_at: sql`now()`,
        })
      )
      .execute();

    const userSyncId = env.USER_SYNC.idFromName(userId);
    const userSyncDO = env.USER_SYNC.get(userSyncId);
    await userSyncDO.fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: userId }),
      })
    );
  } catch (error) {
    logger.error("Failed to notify user sync after trial expiry", error as Error);
  }

  logger.info("Trial expired, downgraded to free", { user_id: userId });
}
