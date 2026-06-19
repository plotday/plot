import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import {
  BUILTIN_TWIST_PACKAGE_ID,
  getPersonalPremiumAddons,
  PLAN_LIMITS,
  selectConnectionsToTrim,
} from "./limits";
import { createLogger } from "@plotday/worker-util";
import { twistFactory } from "../twist";
import { enforcePersonalPlanLimits } from "../twist/management";

/**
 * Find the Plot twist's twist_instance ID for the user who owns a given
 * priority. Twists are workspace-level so there's at most one per user.
 */
export async function getPlotTwistInstanceId(
  db: Kysely<DB>,
  priorityId: string
): Promise<string | null> {
  const priority = await db
    .selectFrom("priority")
    .select("user_id")
    .where("id", "=", priorityId)
    .executeTakeFirst();
  if (!priority?.user_id) return null;

  const row = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select("twist_instance.id")
    .where("twist_instance.owner_id", "=", priority.user_id)
    .where("twist.twist_package_id", "=", BUILTIN_TWIST_PACKAGE_ID)
    .where("twist_instance.archived_at", "is", null)
    .executeTakeFirst();
  return row?.id ?? null;
}

/**
 * Get names of personal connections that exceed the free plan limit.
 * Ordered by connected_at desc (most recent first) — the ones that would be
 * removed on downgrade.
 */
export async function getExcessConnectionNames(
  db: Kysely<DB>,
  userId: string
): Promise<{ twistName: string; provider: string }[]> {
  // Mirror what `enforcePersonalPlanLimits` actually trims on downgrade to free
  // (regular connections beyond the count budget AND premium connections free
  // blocks), so the "you'll lose access to" preview stays consistent with the
  // real removal — including premium connectors like LinkedIn.
  const connections = await db
    .selectFrom("twist_instance_connection as ptc")
    .innerJoin("twist_instance as pt", "pt.id", "ptc.twist_instance_id")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select([
      "ptc.twist_instance_id",
      "ptc.provider",
      "ptc.actor_id",
      "ptc.connected_at",
      "t.premium",
      "t.name as twist_name",
    ])
    .where("ptc.user_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .execute();

  const keyOf = (c: {
    twistInstanceId: string;
    provider: string;
    actorId: string;
  }) => `${c.twistInstanceId}|${c.provider}|${c.actorId}`;
  const nameByKey = new Map(
    connections.map((r) => [
      keyOf({
        twistInstanceId: r.twist_instance_id,
        provider: r.provider,
        actorId: r.actor_id,
      }),
      r.twist_name ?? "Unknown",
    ])
  );

  const premiumAddons = await getPersonalPremiumAddons(db, userId);
  const toTrim = selectConnectionsToTrim(
    connections.map((r) => ({
      twistInstanceId: r.twist_instance_id,
      provider: r.provider,
      actorId: r.actor_id,
      premium: !!r.premium,
      connectedAt: r.connected_at,
    })),
    {
      connections: PLAN_LIMITS.free.connections,
      premium: PLAN_LIMITS.free.premium,
      premiumAddons,
    }
  );

  return toTrim.map((c) => ({
    twistName: nameByKey.get(keyOf(c)) ?? "Unknown",
    provider: c.provider,
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
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select("t.name")
    .where("pt.owner_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
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
  addTodo: boolean,
  plotTwistInstanceId?: string | null
): Promise<void> {
  // Look up user's primary contact for todo tags
  const contact = await db
    .selectFrom("contact")
    .select("id")
    .where("user_id", "=", userId)
    .where("primary", "=", true)
    .executeTakeFirst();

  // Use the Plot twist as author so the note appears from Plot, not the user
  const createdBy = plotTwistInstanceId ?? userId;
  const authorId = plotTwistInstanceId ?? contact?.id ?? userId;

  // Trial notes have no link (authored by Plot system twist), so the
  // partial unique index (thread_id, link_id, key) WHERE key IS NOT NULL
  // can't dedupe them via ON CONFLICT — NULL link_id rows coexist by NULL
  // semantics. Pre-check explicitly to keep this insert idempotent.
  const existing = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", threadId)
    .where("key", "=", key)
    .where("link_id", "is", null)
    .executeTakeFirst();
  if (existing) return; // Already exists (idempotent)

  const note = await db
    .insertInto("note")
    .values({
      thread_id: threadId,
      content,
      created_by: createdBy,
      author_id: authorId,
      key,
    })
    .returning("id")
    .executeTakeFirstOrThrow();

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
 * Find the trial thread for a user: their private welcome-user thread in the
 * Inbox (seeded by activate_invited_user). Reminder/upgrade/expiry notes land
 * on the same thread alongside the welcome message.
 */
async function findTrialThread(
  db: Kysely<DB>,
  userId: string
): Promise<{ threadId: string; priorityId: string; plotTwistInstanceId: string | null } | null> {
  const row = await db
    .selectFrom("thread")
    .innerJoin("thread_priority", "thread_priority.thread_id", "thread.id")
    .select(["thread.id as thread_id", "thread_priority.priority_id"])
    .where("thread.key", "=", "welcome-user")
    .where("thread_priority.user_id", "=", userId)
    .where("thread.archived_at", "is", null)
    .executeTakeFirst();

  if (!row || row.priority_id == null) return null;

  const plotTwistInstanceId = await getPlotTwistInstanceId(db, row.priority_id);

  return { threadId: row.thread_id, priorityId: row.priority_id, plotTwistInstanceId };
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

  const trial = await findTrialThread(db, userId);
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
    false,
    trial.plotTwistInstanceId
  );

  // Complete outstanding todo tags
  await completeTrialTodos(db, trial.threadId);

  // Notify sync for the welcome thread's priority (the user's Inbox)
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
 * Post the 3-day-left reminder. Called from the customer.subscription.trial_will_end
 * webhook (Stripe fires this 3 days before trial_end automatically). Lists
 * what the user will lose if they don't add payment, then links to upgrade.
 */
export async function handleTrialWillEnd(
  db: Kysely<DB>,
  env: Bindings,
  userId: string
): Promise<void> {
  const logger = createLogger({ operation: "handleTrialWillEnd", user_id: userId });

  const trial = await findTrialThread(db, userId);
  if (!trial) {
    logger.warn("Trial thread not found for trial_will_end reminder", { user_id: userId });
    return;
  }

  const siteRoot = env.SITE_ROOT || "https://plot.day";
  const excessConnections = await getExcessConnectionNames(db, userId);
  const excessTwists = await getExcessTwistNames(db, userId);
  const content = buildReminderContent(3, excessConnections, excessTwists, siteRoot);

  await addTrialNote(
    db,
    trial.threadId,
    userId,
    content,
    "reminder-3day",
    true,
    trial.plotTwistInstanceId
  );

  // Notify sync so the new note appears live
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
    logger.error("Failed to notify sync after trial reminder", error as Error);
  }
}

/**
 * Expire a user's reverse trial — downgrade to free and archive excess.
 * Called from the customer.subscription.deleted webhook when Stripe cancels
 * a trial sub at end-of-trial without a payment method.
 */
export async function expireTrial(
  db: Kysely<DB>,
  env: Bindings,
  ctx: ExecutionContext,
  userId: string,
  _stripeCustomerId: string | null
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

  // Get names of what they'll lose before downgrading
  const excessConnections = await getExcessConnectionNames(db, userId);
  const excessTwists = await getExcessTwistNames(db, userId);

  // Downgrade to free. trial_ends_at is left as-is (still useful for "trial
  // expired on date X" UI); handleSubscriptionDeleted clears stripe_subscription_id
  // and creates a fresh free_monthly Stripe sub for tracking.
  await db
    .updateTable("user_subscription")
    .set({ plan: "free" })
    .where("user_id", "=", userId)
    .execute();

  // Enforce the new plan limits using the same archival flow the app uses
  // when a user removes a connection or twist themselves. This ensures the
  // connector's onChannelDisabled callbacks run, so per-connector thread
  // archival (via archiveLinks) happens consistently.
  const factory = twistFactory({ env, ctx, db });
  await enforcePersonalPlanLimits({
    db,
    env,
    twistFactory: factory,
    userId,
    limits: PLAN_LIMITS.free,
  });

  // Add final note to trial thread
  const trial = await findTrialThread(db, userId);
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

    await addTrialNote(db, trial.threadId, userId, content, "expired", false, trial.plotTwistInstanceId);

    // Complete any remaining todos
    await completeTrialTodos(db, trial.threadId);

    // Notify sync for the welcome thread's priority (the user's Inbox)
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
