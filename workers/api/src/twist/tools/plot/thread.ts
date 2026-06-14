import pLimit from "p-limit";
import { PostHog } from "posthog-node";

import { type Database, type Json } from "@plotday/db";
import {
  type Thread,
  type ThreadFilter,
  type Action,
  type ThreadUpdate,
  type ActorId,
  ActorType,
  type NewThread,
  type NewThreadWithNotes,
  type NewNote,
  type Note,
  type Tag,
  type Uuid,
} from "@plotday/twister/plot";
import { ContactAccess, ThreadAccess } from "@plotday/twister/tools/plot";

import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";
import { rpc, rpcUser } from "../../../rpc";
import { logClassificationDecision } from "../../../state/classify-thread";
import {
  cleanTitle,
  handleDbOperationError,
  markThreadReadForAuthor,
  prepareThreadForDb,
  processNewActorArray,
  processTagsActors,
  ThreadFilingSkippedError,
  type PreparedThread,
} from "./thread-helpers";
import { fromDbThread } from "./converters";
import type { Plot } from "./index";
import { addContacts } from "./contacts";
import {
  createNotes,
  ensureIncreasingCreatedTimestamps,
} from "./note";

/**
 * Ensures threads have strictly increasing sourceCreatedAt timestamps.
 * Threads with explicit created field keep it, threads without get assigned
 * incrementally increasing timestamps based on array position.
 */
function ensureIncreasingThreadCreatedTimestamps(
  threads: (NewThread | NewThreadWithNotes)[]
): (NewThread | NewThreadWithNotes)[] {
  if (threads.length === 0) return threads;

  let lastTimestamp = Date.now();

  return threads.map((thread) => {
    if (thread.created) {
      // Thread has explicit timestamp - use it and update tracking
      const threadTime =
        thread.created instanceof Date
          ? thread.created.getTime()
          : new Date(thread.created).getTime();
      lastTimestamp = Math.max(lastTimestamp, threadTime);
      return thread;
    } else {
      // Thread lacks timestamp - assign next incremental value
      lastTimestamp += 1; // 1ms increment
      return {
        ...thread,
        created: new Date(lastTimestamp),
      };
    }
  });
}

// Re-export from split files
export { createNote, createNotes, getNotes, updateNote } from "./note";
export {
  actorTypeToString,
  cleanTitle,
  convertNoteToMarkdown,
  createPreviewFromMarkdown,
  markThreadReadForAuthor,
  prepareThreadForDb,
  processNewActor,
  processNewActorArray,
  processTagsActors,
  type PreparedThread,
} from "./thread-helpers";

/** @deprecated Use markThreadReadForAuthor */
export { markThreadReadForAuthor as markActivityReadForAuthor } from "./thread-helpers";
/** @deprecated Use prepareThreadForDb */
export { prepareThreadForDb as prepareActivityForDb } from "./thread-helpers";
/** @deprecated Use PreparedThread */
export type { PreparedThread as PreparedActivity } from "./thread-helpers";

/**
 * Insert thread_unread rows for users with thread_priority on this thread,
 * so the thread appears unread in their feed. Pairs with the existing
 * thread_read marking: thread_read tracks "user saw it"; thread_unread
 * tracks "should appear unread" and is what user.thread.unread reads from.
 *
 * mode = "non-authors" looks ONLY at notes created in this sync (after
 * `syncStartedAt`) and skips users for whom every such note was authored
 * by one of their linked contacts. Historical notes are intentionally
 * ignored so that, for example, a user replying to a thread they had
 * already read doesn't get re-flagged unread because of the older notes
 * from other people sitting in that thread.
 *
 * mode = "all" marks every priority user unread regardless of authorship —
 * used when the caller passes unread === true.
 *
 * Uses upsert_thread_state with read_at unset (defaults to NULL = unread).
 * The function preserves an existing read_at if the user has read past the
 * latest note (race-guard via p_note_created_at).
 */
async function markThreadUnreadForUsers(
  plot: Plot,
  threadId: string,
  mode: "all" | "non-authors",
  syncStartedAt: Date
): Promise<void> {
  const priorityUsers = await plot.db
    .selectFrom("thread_priority")
    .select("user_id")
    .where("thread_id", "=", threadId)
    .where("archived_at", "is", null)
    .execute();

  if (priorityUsers.length === 0) return;

  // Race guard: don't clobber a read_at the user just set if it's after the
  // most recent note's created timestamp.
  const noteCreatedAt = new Date().toISOString();
  const syncStartedAtIso = syncStartedAt.toISOString();

  for (const { user_id } of priorityUsers) {
    if (mode === "non-authors") {
      // Look only at notes created in this sync. Skip if every such note was
      // authored by one of this user's linked contacts (i.e. they wrote
      // everything that just landed). A single non-self-authored note in the
      // batch still flags the thread unread.
      const otherAuthored = await sql<{ id: string }>`
        SELECT n.id
        FROM note n
        WHERE n.thread_id = ${threadId}::uuid
          AND n.draft = FALSE
          AND n.archived_at IS NULL
          AND n.created_at >= ${syncStartedAtIso}::timestamptz
          AND n.author_id NOT IN (
            SELECT uc.contact_id
            FROM user_contact uc
            WHERE uc.user_id = ${user_id}::uuid
              AND uc.linked = TRUE
              AND uc.archived_at IS NULL
          )
        LIMIT 1
      `.execute(plot.db);

      if (otherAuthored.rows.length === 0) continue;
    }

    try {
      await rpcUser(plot.db, "upsert_thread_state", {
        user_id,
        p_thread_id: threadId,
        p_active: false,
        p_urgent: false,
        p_importance: 50,
        // p_read_at omitted → defaults to NULL; combined with
        // p_set_read_at: true this marks the thread unread (race-safe
        // when p_note_created_at is set).
        p_set_active: false,
        p_set_urgent: false,
        p_set_importance: false,
        p_set_read_at: true,
        p_note_created_at: noteCreatedAt,
      });
    } catch (err) {
      const logger = createLogger({
        twist_instance_id: plot.twistInstanceId,
      });
      logger.error("Failed to mark thread unread", err as Error, {
        thread_id: threadId,
        user_id,
      });
    }
  }
}

/**
 * upsert_thread can merge into an existing thread (source match); only a
 * freshly-created row carries this call's pre-insert classification
 * decision. created_at within 60s of now ⇒ created by this call.
 *
 * The window's sole job is tolerating worker↔DB wall-clock skew
 * (created_at is the DB's now()); request latency is negligible. A false
 * negative just drops one mining row; a false positive requires a merge
 * within the window, which still attributes this call's real decision.
 */
function isFreshlyCreated(createdAt: string | Date): boolean {
  return Math.abs(Date.now() - new Date(createdAt).getTime()) < 60_000;
}

export async function createThread(
  plot: Plot,
  activity: NewThread | NewThreadWithNotes,
  skipNotify = false
): Promise<{ id: Uuid; priorityId: string; authorId: string }> {
  try {
    // Use shared helper for all preparation logic
    const prepared = await prepareThreadForDb(plot, activity);
    if (!prepared) {
      // Team-connector thread with no matching team priority for this user.
      // Skip filing by throwing the marker error: callers in this worker
      // (integrations.saveLink) catch it and return null so connector batches
      // continue, and handleTwistOperation suppresses it from error reporting.
      throw new ThreadFilingSkippedError();
    }
    const { priorityId, authorId, pendingDecision, ...prep } = prepared;

    // Set icon for twist-created threads if not already set by caller (e.g. createLink)
    // Skip auto-icon if the SDK 'type' field was set (mapped to icon by prepareThreadForDb)
    if (
      (!("icon" in activity) || (activity as any).icon === undefined) &&
      (!("type" in activity) || (activity as any).type === undefined)
    ) {
      const ptRow = await plot.db
        .selectFrom("twist_instance")
        .select("twist_id")
        .where("id", "=", plot.twistInstanceId)
        .executeTakeFirst();
      if (ptRow) {
        const iconValue = `twist:${ptRow.twist_id}`;
        if ("insert" in prep) {
          (prep as any).insert.icon = iconValue;
        } else if ("upsert" in prep) {
          (prep as any).upsert.icon = iconValue;
          (prep as any).defaults.icon = iconValue;
        }
      }
    }

    // Insert or upsert activity based on whether it has a source.
    let dbResult: {
      id: string;
      created_at: string | Date;
    };

    if ("upsert" in prep) {
      // Use database function for source-based upsert
      // RPC returns full activity row directly
      const userId = await plot.getUserId();
      try {
        dbResult = await rpcUser(plot.db, "upsert_thread", {
          user_id: userId,
          p_thread: prep.upsert as Json,
          p_defaults: { ...prep.defaults, priority_id: priorityId } as Json,
        });
      } catch (error) {
        const logger = createLogger({ component: "plot_tool" });
        logger.error("upsert_activity failed", error as Error, {
          upsert: JSON.stringify(prep.upsert),
          defaults: JSON.stringify(prep.defaults),
        });
        const postHog = new PostHog(plot.env.POSTHOG_API_KEY, { host: plot.env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
        postHog.captureException(error as Error, userId, {
          context: "plot:upsertThread",
          twist_instance_id: plot.twistInstanceId,
          upsert: JSON.stringify(prep.upsert),
          defaults: JSON.stringify({ ...prep.defaults, priority_id: priorityId }),
        });
        await postHog.shutdown();
        throw error;
      }
    } else {
      // Plain insert for activities without source
      dbResult = await plot.db
        .insertInto("thread")
        // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
        .values(prep.insert)
        .returningAll()
        .executeTakeFirstOrThrow();
    }

    // Log the pre-insert classification decision now that the thread row
    // exists. Skip merged rows (upsert_thread source match) — only a
    // freshly-created row carries this call's decision.
    if (pendingDecision && isFreshlyCreated(dbResult.created_at)) {
      await logClassificationDecision(plot.db, plot.env, {
        ...pendingDecision,
        threadId: dbResult.id,
      });
    }

    // Process series-level tags if provided - convert NewActor[] to ActorId[] for each tag (batched)
    let processedTags: Partial<Record<number, ActorId[]>> | null = null;
    if (activity.tags) {
      processedTags = await processTagsActors(plot, activity.tags, priorityId);
    }

    // Add series-level tags if provided
    if (processedTags) {
      // Build tag records with proper actor IDs from the processed tags object
      // Note: Regular activities don't have occurrence (it's in activity_exception table)
      // For series-level tags, occurrence is null
      const newTags = Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            thread_id: dbResult.id,
            occurrence: null, // Series-level tags for regular activities
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (newTags.length > 0) {
        await plot.db
          .insertInto("thread_tag")
          .values(newTags)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
              .doUpdateSet((eb) => ({
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Add reactions if provided. Parallel to the tag block above but
    // keyed by emoji string (Unicode grapheme or
    // `provider:workspace/name` custom-emoji ref). Series-level
    // reactions on regular threads have occurrence = null.
    if (activity.reactions) {
      const reactionInserts: Array<{
        thread_id: string;
        occurrence: string | null;
        emoji: string;
        actor_id: string;
        updated_by: number;
        sync_depth: number;
      }> = [];
      for (const [emoji, newActors] of Object.entries(activity.reactions)) {
        if (!newActors || newActors.length === 0) continue;
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          priorityId
        );
        for (const actorId of actorIds) {
          reactionInserts.push({
            thread_id: dbResult.id,
            occurrence: null,
            emoji,
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          });
        }
      }
      if (reactionInserts.length > 0) {
        await plot.db
          .insertInto("thread_reaction")
          .values(reactionInserts)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "thread_id", "occurrence", "emoji"])
              .doUpdateSet((eb) => ({
                archived_at: null,
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Capture a boundary just before createNotes so the unread-marking step
    // below can scope its "any other-authored note?" check to this sync's
    // notes only. Older notes (e.g. a thread the user already read) must not
    // count — otherwise a user replying to an existing thread would re-flag
    // it unread for themselves because of historical notes from others.
    const syncStartedAt = new Date();

    // Create initial notes if provided
    if ("notes" in activity && activity.notes && activity.notes.length > 0) {
      await createNotes(
        plot,
        activity.notes.map((note) => ({
          ...note,
          // dbResult.id is a string from the database, but NewNote.thread.id expects a branded Uuid type.
          // The cast is safe because database IDs are valid UUIDs.
          thread: { id: dbResult.id as Uuid },
        })),
        { priority_id: priorityId, created_by: plot.twistInstanceId }
      );
    }

    // Mark as read based on unread flag:
    // - false: mark read for ALL priority users (initial sync)
    // - undefined/omitted: mark read for author only if they are the twist owner
    // - true: explicitly unread for all (do nothing)
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    const shouldMarkAllAsRead = activity?.unread === false;

    if (shouldMarkAllAsRead) {
      // Mark read for ALL priority users
      // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
      // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
      const usersData = await rpc(plot.db, "get_users_with_priority_access", {
        target_priority_id: priorityId,
      });
      const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

      if (userIds.length > 0) {
        try {
          await sql`
            INSERT INTO thread_read (user_id, thread_id, read_at)
            SELECT uid, ${dbResult.id}::uuid, now()
            FROM unnest(${userIds}::uuid[]) AS uid
            ON CONFLICT (user_id, thread_id) DO UPDATE SET read_at = EXCLUDED.read_at
          `.execute(plot.db);
        } catch (err) {
          const logger = createLogger({
            twist_instance_id: plot.twistInstanceId,
          });
          logger.error(
            "Failed to upsert activity_read entries",
            err as Error,
            {
              thread_id: dbResult.id,
              count: userIds.length,
            }
          );
        }
      }
    } else if (activity?.unread === undefined) {
      // Default: mark read for the activity author and each note author
      // Use current time — always >= any source timestamp (which are historical),
      // avoids PG microsecond vs JS millisecond precision mismatch
      const readTimestamp = new Date().toISOString();

      // Mark read for the activity's author
      await markThreadReadForAuthor(
        plot,
        authorId,
        dbResult.id,
        readTimestamp
      );

      // Also mark read for each unique note author linked to a user
      const noteAuthors = await plot.db
        .selectFrom("note")
        .innerJoin("contact", "contact.id", "note.author_id")
        .select("note.author_id")
        .distinct()
        .where("note.thread_id", "=", dbResult.id)
        .where("note.author_id", "is not", null)
        .where("note.author_id", "!=", authorId)
        .where("note.author_id", "!=", plot.twistInstanceId)
        .where("contact.user_id", "is not", null)
        .execute();

      for (const row of noteAuthors) {
        if (row.author_id) {
          await markThreadReadForAuthor(
            plot,
            row.author_id,
            dbResult.id,
            readTimestamp
          );
        }
      }
    }
    // unread === true: do nothing (explicitly unread for all)

    // Insert thread_unread rows so the thread appears unread for the right
    // users. Without this, twist-authored threads (e.g. Gmail messages) never
    // get a thread_unread row: file_thread_priority_peers early-exits for
    // twist-authored threads, upsert_thread only inserts thread_unread for
    // promoted_contacts (not the calling user), and the channelNewNotes path
    // in queue/updates.ts only fires when an observing twist exists. The
    // user.thread view computes `unread` from thread_unread.read_at, so
    // missing rows render as already-read.
    //
    // Authors are excluded so a user syncing in a thread they themselves
    // authored content for (e.g. Gmail message they sent) doesn't see it
    // unread. unread === true bypasses the author exclusion to honor the
    // explicit request.
    if (activity?.unread !== false) {
      await markThreadUnreadForUsers(
        plot,
        dbResult.id,
        activity?.unread === true ? "all" : "non-authors",
        syncStartedAt
      );
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes.
    // createLink passes skipNotify=true so it can batch one notify after the
    // link row exists — otherwise clients receive the thread with no link yet
    // and activity_at falls back to created_at=now() until the link arrives.
    if (!skipNotify) {
      await plot.notifySyncDOs(new Set([priorityId]));
    }

    return { id: dbResult.id as Uuid, priorityId, authorId };
  } catch (error) {
    throw await handleDbOperationError(error, "createThread", plot, {
      has_notes: "notes" in activity && !!activity.notes?.length,
      has_source: "source" in activity && !!activity.source,
      has_id: "id" in activity && !!activity.id,
    });
  }
}

async function updateThreadsByMatch(
  plot: Plot,
  activity: ThreadUpdate & { match: ThreadFilter }
): Promise<void> {
  const { match } = activity;

  // Filter to activities created by this twist instance
  let query = plot.db
    .updateTable("thread")
    .where("created_by", "=", plot.twistInstanceId);

  // Apply meta filter using jsonb containment (via link table if needed)
  if (match.meta) {
    query = query.where(
      sql<boolean>`id IN (SELECT thread_id FROM link WHERE meta @> ${JSON.stringify(match.meta)}::jsonb)`
    );
  }

  // Build update object - only scalar fields for bulk updates
  const dbUpdate: Omit<Database["public"]["Tables"]["thread"]["Update"], "seq" | "last_note_seq"> = {
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
  };

  if (activity.archived !== undefined) {
    dbUpdate.archived_at = activity.archived
      ? new Date().toISOString()
      : null;
  }
  if (activity.title !== undefined) {
    dbUpdate.title =
      activity.title && activity.title.trim() !== ""
        ? cleanTitle(activity.title)
        : null;
  }
  // Resolve accessContacts from NewContact[] to ActorId[]
  let resolvedAccessContacts: ActorId[] | undefined;
  if (activity.accessContacts && activity.accessContacts.length > 0) {
    const actors = await addContacts(plot, activity.accessContacts);
    resolvedAccessContacts = actors.map((a) => a.id);
  }

  if (resolvedAccessContacts !== undefined) {
    dbUpdate.contacts = resolvedAccessContacts;
  }

  // Check if there are meaningful updates
  const meaningfulKeys = Object.keys(dbUpdate).filter(
    (key) => !["updated_by", "sync_depth"].includes(key)
  );
  if (meaningfulKeys.length === 0) {
    return;
  }

  // Execute bulk update, returning affected thread IDs for sync notification
  const results = await query
    // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
    .set(dbUpdate)
    .returning("id")
    .execute();

  // Look up affected priority_ids via thread_priority and notify sync DOs
  if (results.length > 0) {
    const threadIds = results.map((r) => r.id);
    const tpRows = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "in", threadIds)
      .execute();
    const affectedPriorityIds = new Set(
      tpRows
        .map((r) => r.priority_id)
        .filter((id): id is string => id != null)
    );
    await plot.notifySyncDOs(affectedPriorityIds);
  }
}

export async function updateThread(
  plot: Plot,
  activity: ThreadUpdate
): Promise<void> {
  try {
    // Handle bulk update by match filter
    if ("match" in activity && activity.match) {
      return updateThreadsByMatch(plot, activity as ThreadUpdate & { match: ThreadFilter });
    }

    // Determine activity ID - either provided directly or looked up by source
    let activityId: string;

    if ("id" in activity && activity.id) {
      activityId = activity.id;
    } else if ("source" in activity && activity.source) {
      // Look up thread by source via link table
      const found = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source", "=", activity.source)
        .executeTakeFirst();

      if (!found || !found.thread_id) {
        throw new Error(`Activity not found for source: ${activity.source}`);
      }
      activityId = found.thread_id;
    } else {
      throw new Error("Activity update must provide either id or source");
    }

    // Enforce per-twist permission level. A twist holding only
    // ThreadAccess.Respond (or installed with requireApproval) must not be
    // able to update arbitrary threads it merely observed; the validator
    // checks created_by / mentions / approval-gate just like the create
    // path does.
    await plot.validateActivityUpdateAccess(activityId);

    // Build update object
    const dbUpdate: Omit<Database["public"]["Tables"]["thread"]["Update"], "seq" | "last_note_seq"> = {
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
    };

    if (activity.title !== undefined) {
      dbUpdate.title =
        activity.title && activity.title.trim() !== ""
          ? cleanTitle(activity.title)
          : null;
    }
    // Resolve accessContacts from NewContact[] to ActorId[]
    let resolvedAccessContacts: ActorId[] | undefined;
    if (activity.accessContacts && activity.accessContacts.length > 0) {
      const actors = await addContacts(plot, activity.accessContacts);
      resolvedAccessContacts = actors.map((a) => a.id);
    }

    if (resolvedAccessContacts !== undefined) {
      dbUpdate.contacts = resolvedAccessContacts;
    }
    if (activity.archived !== undefined) {
      dbUpdate.archived_at = activity.archived
        ? new Date().toISOString()
        : null;
    }
    if ("type" in activity && (activity as any).type !== undefined) {
      (dbUpdate as any).icon = (activity as any).type;
    }

    // Handle priority move (thread reparenting via thread_priority)
    let oldPriorityId: string | undefined;
    if ("priority" in activity && (activity as any).priority?.id) {
      plot.requireThreadAccess(ThreadAccess.Full);

      const targetPriorityId = (activity as any).priority.id as string;
      await plot.validatePriorityAccess(targetPriorityId);

      // Get current priority for sync notification
      const userId = await plot.getUserId();
      const current = await plot.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", activityId)
        .where("user_id", "=", userId)
        .executeTakeFirst();
      oldPriorityId = current?.priority_id ?? undefined;

      // Update thread_priority instead of thread.priority_id
      await plot.db
        .insertInto("thread_priority")
        .values({ thread_id: activityId, user_id: userId, priority_id: targetPriorityId })
        .onConflict((oc) => oc.columns(["thread_id", "user_id"]).doUpdateSet({ priority_id: targetPriorityId }))
        .execute();
    }

    // Check if there are meaningful updates (beyond updated_by, sync_depth, occurrence)
    const meaningfulKeys = Object.keys(dbUpdate).filter(
      (key) => !["updated_by", "sync_depth", "occurrence"].includes(key)
    );
    const hasMeaningfulUpdates = meaningfulKeys.length > 0;

    // Execute the update only if there are meaningful changes
    if (hasMeaningfulUpdates) {
      const updatedActivity = await plot.db
        .updateTable("thread")
        // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
        .set(dbUpdate)
        .where("id", "=", activityId)
        .returning("id")
        .executeTakeFirst();

      if (!updatedActivity) {
        throw new Error(`Activity not found: ${activityId}`);
      }
    }

    // Handle full tags object replacement (only for activities created by this twist or another instance of the same twist)
    if (activity.tags !== undefined) {
      // Query for created_by from thread and priority_id from thread_priority
      const activityData = await plot.db
        .selectFrom("thread")
        .select("created_by")
        .where("id", "=", activityId)
        .executeTakeFirst();

      if (!activityData) {
        throw new Error("Failed to fetch activity: Not found");
      }
      const { created_by: createdBy } = activityData;

      const userId = await plot.getUserId();
      const tpRow = await plot.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", activityId)
        .where("user_id", "=", userId)
        .executeTakeFirst();
      let priorityId: string;
      if (tpRow?.priority_id) {
        priorityId = tpRow.priority_id;
      } else {
        // Fallback when thread_priority has no row for this user. Focuses are
        // team-agnostic, so file under the user's root regardless of team —
        // team scope lives on thread.team_id, not on the priority.
        priorityId = await plot.getRootPriorityId(userId);
      }

      // Check if activity was created by this exact instance (fast path)
      const isExactInstance = createdBy === plot.twistInstanceId;
      // Or check if activity was created by another instance of the same twist (fallback)
      const isSameTwist =
        !isExactInstance &&
        createdBy &&
        (await plot.isSameTwistDefinition(createdBy));

      if (!isExactInstance && !isSameTwist) {
        throw new Error(
          `Cannot update tags field: activity was not created by this twist (activity.createdBy: ${createdBy}, twist: ${plot.twistInstanceId}). Use twistTags instead to add/remove tags for this twist.`
        );
      }

      // Delete all existing tags for this activity
      await plot.db
        .deleteFrom("thread_tag")
        .where("thread_id", "=", activityId)
        .execute();

      // Process tags - convert NewActor[] to ActorId[] for each tag (batched)
      const processedTags = await processTagsActors(
        plot,
        activity.tags,
        priorityId
      );

      // Insert new tags
      // Note: This updates series-level tags (occurrence=null)
      // For occurrence-specific tags, use NewThread.occurrences field
      const newTags = Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            thread_id: activityId,
            occurrence: null, // Series-level tags
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (newTags.length > 0) {
        await plot.db
          .insertInto("thread_tag")
          .values(newTags)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
              .doUpdateSet((eb) => ({
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Handle reactions if provided. Mirrors the tag block above: passing
    // `reactions` declares the full reaction state, so clear and replace.
    // Resolves priority for the connector locally — the tag branch's
    // priorityId is scoped inside its own `if`.
    if (activity.reactions !== undefined) {
      const userId = await plot.getUserId();
      const tpRow = await plot.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", activityId)
        .where("user_id", "=", userId)
        .executeTakeFirst();
      const reactionPriorityId =
        tpRow?.priority_id ?? (await plot.getRootPriorityId(userId));

      await plot.db
        .deleteFrom("thread_reaction")
        .where("thread_id", "=", activityId)
        .where("occurrence", "is", null)
        .execute();

      const reactionInserts: Array<{
        thread_id: string;
        occurrence: string | null;
        emoji: string;
        actor_id: string;
        updated_by: number;
        sync_depth: number;
      }> = [];
      for (const [emoji, newActors] of Object.entries(activity.reactions)) {
        if (!newActors || newActors.length === 0) continue;
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          reactionPriorityId
        );
        for (const actorId of actorIds) {
          reactionInserts.push({
            thread_id: activityId,
            occurrence: null,
            emoji,
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          });
        }
      }
      if (reactionInserts.length > 0) {
        await plot.db
          .insertInto("thread_reaction")
          .values(reactionInserts)
          .execute();
      }
    }

    // Handle twist tags separately using RPC (for adding/removing caller's own tags)
    // Note: RSVP tags (Attend/Skip/Undecided) are mutually exclusive -
    // the database function automatically removes conflicting RSVP tags.
    // Count tags can only be modified for the current user (enforced by RLS).
    if (activity.twistTags) {
      const userId = await plot.getUserId();
      await rpcUser(plot.db, "update_thread_tags", {
        user_id: userId,
        p_thread_id: activityId,
        p_actor_id: plot.twistInstanceId,
        p_client_id: plot.getUpdatedBy(),
        p_tag_updates: activity.twistTags,
      });
    }

    // Only notify sync DOs if we actually wrote something
    const hasTagUpdates = activity.tags !== undefined || activity.twistTags !== undefined;
    if (hasMeaningfulUpdates || hasTagUpdates) {
      // Look up the thread's current priority for sync notification.
      const tpNotify = await plot.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", activityId)
        .executeTakeFirst();
      const currentPriorityId =
        tpNotify?.priority_id ?? (await plot.getRootPriorityId());
      const prioritiesToNotify = new Set([currentPriorityId]);
      // If thread was moved, also notify the old priority
      if (oldPriorityId && oldPriorityId !== currentPriorityId) {
        prioritiesToNotify.add(oldPriorityId);
      }
      await plot.notifySyncDOs(prioritiesToNotify);
    }
  } catch (error) {
    throw await handleDbOperationError(error, "updateThread", plot, {
      has_activity_id: "id" in activity && !!activity.id,
      has_source: "source" in activity && !!activity.source,
      update_fields: Object.keys(activity).filter(
        (k) => k !== "id" && k !== "source"
      ),
    });
  }
}

export async function getThread(
  plot: Plot,
  activity: { id: Uuid } | { source: string }
): Promise<Thread | null> {
  try {
    // Resolve thread ID
    let activityId: string | undefined;

    if ("id" in activity) {
      activityId = activity.id;
    } else {
      // Source-based lookup via link table
      const found = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source", "=", activity.source)
        .executeTakeFirst();
      activityId = found?.thread_id ?? undefined;
    }

    if (!activityId) {
      return null;
    }

    const userId = await plot.getUserId();
    const data = await plot.db
      .selectFrom("user.thread")
      .selectAll("user.thread")
      .where("user_id", "=", userId)
      .where("id", "=", activityId)
      .limit(1)
      .executeTakeFirst();

    if (!data) {
      return null;
    }

    // Fetch tags for the thread
    const tagsData = data.id
      ? await plot.db
          .selectFrom("thread_tags")
          .select("tags")
          .where("thread_id", "=", data.id)
          .executeTakeFirst()
      : null;

    const createdAtStr =
      data.created_at instanceof Date
        ? data.created_at.toISOString()
        : (data.created_at ?? new Date().toISOString());
    const updatedAtStr =
      data.updated_at instanceof Date
        ? data.updated_at.toISOString()
        : (data.updated_at ?? new Date().toISOString());

    return fromDbThread(
      plot,
      // @ts-ignore - Kysely returns Date for timestamp columns, but fromDbThread expects Supabase Row types with string timestamps
      {
        ...data,
        id: data.id ?? "",
        created_at: createdAtStr,
        updated_at: updatedAtStr,
        created_by: (data as any).created_by ?? "",
        draft: data.draft ?? false,
        contacts: data.contacts ?? [],
        updated_by: data.updated_by ?? 0,
        sync_depth: null,
        tags: tagsData?.tags || null,
      }
    );
  } catch (err) {
    const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
    logger.error("Failed to get activity", err as Error);
    throw err;
  }
}

export async function getNote(
  plot: Plot,
  note: { id: Uuid } | { key: string }
): Promise<Note | null> {
  try {
    // Build the query to fetch the note
    let query = plot.db
      .selectFrom("note")
      .select([
        "id",
        "created_at",
        "source_created_at",
        "updated_at",
        "author_id",
        "created_by",
        "updated_by",
        "archived_at",
        "thread_id",
        "draft",
        "access_contacts",
        "content",
        "key",
        "actions",
        "mentions",
        "re_note_id",
      ]);

    // Query by id or key
    if ("id" in note) {
      query = query.where("id", "=", note.id);
    } else {
      // For connector callers, restrict to notes on a link owned by this
      // connector so reply-by-key targeting on a merged thread doesn't pick
      // a sibling connector's note with the same key.
      const twistInstanceId = plot.twistInstanceId;
      query = query
        .where("note.key", "=", note.key)
        .$if(twistInstanceId != null, (qb) =>
          qb
            .innerJoin("link", "link.id", "note.link_id")
            .where("link.created_by", "=", twistInstanceId!)
        );
    }

    // Always include archived notes (no filter on archived_at)

    const data = await query.limit(1).executeTakeFirst();

    if (!data) {
      return null;
    }

    // Fetch author separately
    const author = await plot.db
      .selectFrom("actor")
      .select([
        "id",
        "name",
        "type",
        "email",
        "archived_at",
        "avatar_url",
        "created_at",
        "updated_at",
      ])
      .where("id", "=", data.author_id)
      .executeTakeFirst();

    if (!author) {
      throw new Error("Note author not found");
    }

    // Validate access to the priority via the activity
    // First fetch the activity to get the priority
    const tpData = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", data.thread_id)
      .where("user_id", "=", await plot.getUserId())
      .executeTakeFirst();

    if (!tpData) {
      throw new Error(`Activity not found for note`);
    }

    if (tpData.priority_id) {
      await plot.validatePriorityAccess(tpData.priority_id);
    }

    // Fetch the full activity for the note
    const activity = await getThread(plot, { id: data.thread_id as Uuid });
    if (!activity) {
      throw new Error(`Activity not found for note`);
    }

    // Fetch tags for the note
    const tagsData = await plot.db
      .selectFrom("note_tags")
      .select("tags")
      .where("note_id", "=", data.id)
      .executeTakeFirst();

    // Check if ContactAccess.Read permission is granted to include author email
    const includeAuthorEmail =
      plot.plotOptions?.contact?.access !== undefined &&
      plot.plotOptions.contact.access >= ContactAccess.Read;

    return {
      id: data.id as Uuid,
      created: data.source_created_at
        ? new Date(data.source_created_at)
        : new Date(data.created_at),
      thread: activity,
      author: {
        id: author.id as ActorId,
        type: (author.type ?? ActorType.Contact) as ActorType,
        name: author.name ?? null,
        email: includeAuthorEmail ? author.email ?? undefined : undefined,
      },
      accessContacts: (data.access_contacts as ActorId[]) ?? null,
      archived: data.archived_at !== null,
      content: data.content,
      key: data.key || null,
      reNote: data.re_note_id ? { id: data.re_note_id as Uuid } : null,
      actions: data.actions as Action[] | null,
      mentions: (data.mentions as string[])?.map((m) => m as ActorId) ?? [],
      tags: (tagsData?.tags as Partial<Record<Tag, ActorId[]>> | null) || {},
      reactions: {},
      cta: null,
    };
  } catch (err) {
    const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
    logger.error("Failed to get note", err as Error);
    throw err;
  }
}

export async function createThreads(
  plot: Plot,
  activities: (NewThread | NewThreadWithNotes)[]
): Promise<Uuid[]> {
  if (activities.length === 0) {
    return [];
  }

  try {
    // Ensure activities without created timestamps get strictly increasing values
    const processedActivities =
      ensureIncreasingThreadCreatedTimestamps(activities);

    const limit = pLimit(5);
    type DbActivity = { id: string; created_at: string | Date; priority_id: string };
    // dbActivities is sized after filtering — allocated below once filteredActivities is known.
    let dbActivities: DbActivity[];

    const allPreparedActivities = await Promise.all(
      processedActivities.map((activity) =>
        limit(() => prepareThreadForDb(plot, activity))
      )
    );

    // Filter out activities that could not be filed (e.g. team-connector thread
    // with no matching team priority for this user). Keep original and prepared
    // in sync via a paired filter.
    const filteredActivities: (NewThread | NewThreadWithNotes)[] = [];
    const preparedActivities: PreparedThread[] = [];
    for (let i = 0; i < processedActivities.length; i++) {
      const prepared = allPreparedActivities[i];
      if (prepared != null) {
        filteredActivities.push(processedActivities[i]!);
        preparedActivities.push(prepared);
      }
    }

    if (preparedActivities.length === 0) {
      return [];
    }

    dbActivities = new Array(preparedActivities.length);

    // Set icon for twist-created threads (single lookup for all activities)
    const ptRowBatch = await plot.db
      .selectFrom("twist_instance")
      .select("twist_id")
      .where("id", "=", plot.twistInstanceId)
      .executeTakeFirst();
    if (ptRowBatch) {
      const iconValue = `twist:${ptRowBatch.twist_id}`;
      for (let i = 0; i < preparedActivities.length; i++) {
        const activity = filteredActivities[i];
        // Skip if caller already set icon (e.g. createLink) or type (SDK sub-type)
        if ("icon" in activity && (activity as any).icon !== undefined) continue;
        if ("type" in activity && (activity as any).type !== undefined) continue;
        const prepared = preparedActivities[i];
        if ("insert" in prepared) {
          (prepared as any).insert.icon = iconValue;
        } else if ("upsert" in prepared) {
          (prepared as any).upsert.icon = iconValue;
          (prepared as any).defaults.icon = iconValue;
        }
      }
    }

    // Batch insert non-source activities
    const nonSourceInserts = preparedActivities
      .filter((pa) => "insert" in pa)
      .map((pa) => pa.insert);

    const nonSourceResults =
      nonSourceInserts.length > 0
        ? await plot.db
            .insertInto("thread")
            // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
            .values(nonSourceInserts)
            .returning(["id", "created_at"])
            .execute()
        : [];

    // Upsert source-based activities
    let nonSourceIndex = 0;
    const userId = await plot.getUserId();
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          if (!("upsert" in prepared)) {
            const result = nonSourceResults[nonSourceIndex++];
            dbActivities[index] = { ...result, priority_id: prepared.priorityId } as DbActivity;
            return;
          }
          const { upsert, defaults } = prepared;
          const dbResult = await rpcUser(plot.db, "upsert_thread", {
            user_id: userId,
            p_thread: upsert as Json,
            p_defaults: { ...defaults, priority_id: prepared.priorityId } as Json,
          });
          dbActivities[index] = { ...dbResult, priority_id: prepared.priorityId } as DbActivity;
        })
      )
    );

    // Log pre-insert classification decisions now that thread ids exist.
    // Skip merged rows (upsert_thread source match) via the freshness guard.
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          const row = dbActivities[index];
          if (!prepared.pendingDecision || !row) return;
          if (!isFreshlyCreated(row.created_at)) return;
          await logClassificationDecision(plot.db, plot.env, {
            ...prepared.pendingDecision,
            threadId: row.id,
          });
        })
      )
    );

    // Process series-level tags for all activities
    const processedTagsArray: Array<Partial<Record<number, ActorId[]>> | null> =
      new Array(preparedActivities.length);

    await Promise.all(
      filteredActivities.map((activity, index) =>
        limit(async () => {
          if (!activity.tags) {
            processedTagsArray[index] = null;
            return;
          }

          const processedTags = await processTagsActors(
            plot,
            activity.tags,
            dbActivities[index].priority_id
          );
          processedTagsArray[index] =
            Object.keys(processedTags).length > 0 ? processedTags : null;
        })
      )
    );

    // Add series-level tags for activities that have them
    const allTags = processedTagsArray.flatMap((processedTags, i) => {
      if (!processedTags) return [];

      const dbActivity = dbActivities[i];
      return Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            thread_id: dbActivity.id,
            occurrence: null,
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );
    });

    if (allTags.length > 0) {
      await plot.db
        .insertInto("thread_tag")
        .values(allTags)
        .onConflict((oc) =>
          oc
            .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
            .doUpdateSet((eb) => ({
              updated_by: eb.ref("excluded.updated_by"),
              sync_depth: eb.ref("excluded.sync_depth"),
            }))
        )
        .execute();
    }

    // Create notes for all activities, grouped by priority to pass context
    // and avoid redundant activity fetches inside createNote.
    const notesByPriority = new Map<string, NewNote[]>();
    for (let index = 0; index < filteredActivities.length; index++) {
      const activity = filteredActivities[index];
      if (
        !("notes" in activity) ||
        !activity.notes ||
        activity.notes.length === 0
      ) {
        continue;
      }

      // Preprocess timestamps for this activity's notes
      // Cast is safe: helper only examines 'created' field, not 'activity'
      const processedActivityNotes = ensureIncreasingCreatedTimestamps(
        activity.notes as NewNote[]
      );

      const priorityId = dbActivities[index].priority_id;
      const mapped = processedActivityNotes.map(
        (note): NewNote => ({
          ...note,
          thread: { id: dbActivities[index].id as Uuid },
        })
      );

      const existing = notesByPriority.get(priorityId);
      if (existing) {
        existing.push(...mapped);
      } else {
        notesByPriority.set(priorityId, mapped);
      }
    }

    // Create notes for each priority group, passing context to skip
    // redundant activity fetches inside createNote.
    for (const [priorityId, notes] of notesByPriority) {
      await createNotes(plot, notes, { priority_id: priorityId, created_by: plot.twistInstanceId });
    }

    // Mark activities as read based on unread flag:
    // - false: mark read for ALL priority users (initial sync)
    // - undefined/omitted: mark read for author only if they are the twist owner
    // - true: explicitly unread for all (do nothing)
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    const activitiesToMarkAllAsRead: Array<{
      dbActivity: DbActivity;
      originalActivity: NewThread | NewThreadWithNotes;
    }> = [];
    const activitiesToMarkAuthorAsRead: Array<{
      dbActivity: DbActivity;
      authorId: string;
    }> = [];

    for (let i = 0; i < filteredActivities.length; i++) {
      const originalActivity = filteredActivities[i];
      const shouldMarkAllAsRead = originalActivity?.unread === false;

      if (shouldMarkAllAsRead) {
        activitiesToMarkAllAsRead.push({
          dbActivity: dbActivities[i],
          originalActivity,
        });
      } else if (originalActivity?.unread === undefined) {
        activitiesToMarkAuthorAsRead.push({
          dbActivity: dbActivities[i],
          authorId: preparedActivities[i].authorId,
        });
      }
    }

    if (activitiesToMarkAllAsRead.length > 0) {
      // Group activities by priority_id to minimize database queries
      const activitiesByPriority = new Map<
        string,
        typeof activitiesToMarkAllAsRead
      >();
      for (const item of activitiesToMarkAllAsRead) {
        const priorityId = item.dbActivity.priority_id;
        if (!activitiesByPriority.has(priorityId)) {
          activitiesByPriority.set(priorityId, []);
        }
        activitiesByPriority.get(priorityId)!.push(item);
      }

      // For each priority, get users and insert thread_read entries with now()
      // Using SQL now() avoids PG microsecond vs JS millisecond precision mismatch
      await Promise.all(
        Array.from(activitiesByPriority.entries()).map(
          ([priorityId, priorityActivities]) =>
            limit(async () => {
              // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
              // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
              const usersData = await rpc(
                plot.db,
                "get_users_with_priority_access",
                {
                  target_priority_id: priorityId,
                }
              );
              const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

              if (userIds.length === 0) {
                return;
              }

              const threadIds = priorityActivities.map(
                (item) => item.dbActivity.id
              );

              try {
                await sql`
                  INSERT INTO thread_read (user_id, thread_id, read_at)
                  SELECT uid, tid, now()
                  FROM unnest(${userIds}::uuid[]) AS uid
                  CROSS JOIN unnest(${threadIds}::uuid[]) AS tid
                  ON CONFLICT (user_id, thread_id) DO UPDATE SET read_at = EXCLUDED.read_at
                `.execute(plot.db);
              } catch (err) {
                const logger = createLogger({
                  twist_instance_id: plot.twistInstanceId,
                });
                logger.error(
                  "Failed to upsert activity_read entries for batch activities",
                  err as Error,
                  {
                    count: userIds.length * threadIds.length,
                  }
                );
              }
            })
        )
      );
    }

    // Mark read for author only (when unread is omitted/undefined)
    if (activitiesToMarkAuthorAsRead.length > 0) {
      const authorActivityIds = activitiesToMarkAuthorAsRead.map(
        (a) => a.dbActivity.id
      );

      // Use current time — always >= any source timestamp (which are historical),
      // avoids PG microsecond vs JS millisecond precision mismatch
      const readTimestamp = new Date().toISOString();

      await Promise.all(
        activitiesToMarkAuthorAsRead.map((item) =>
          limit(async () => {
            await markThreadReadForAuthor(
              plot,
              item.authorId,
              item.dbActivity.id,
              readTimestamp
            );
          })
        )
      );

      // Also mark read for unique note authors linked to users
      const authorIdsByActivity = new Map<string, Set<string>>(
        activitiesToMarkAuthorAsRead.map((item) => [
          item.dbActivity.id,
          new Set([item.authorId, plot.twistInstanceId]),
        ])
      );

      const noteAuthorRows = await plot.db
        .selectFrom("note")
        .innerJoin("contact", "contact.id", "note.author_id")
        .select(["note.thread_id", "note.author_id"])
        .distinct()
        .where("note.thread_id", "in", authorActivityIds)
        .where("note.author_id", "is not", null)
        .where("note.author_id", "!=", plot.twistInstanceId)
        .where("contact.user_id", "is not", null)
        .execute();

      await Promise.all(
        noteAuthorRows
          .filter((row) => {
            const excluded = authorIdsByActivity.get(row.thread_id);
            return row.author_id && (!excluded || !excluded.has(row.author_id));
          })
          .map((row) =>
            limit(async () => {
              await markThreadReadForAuthor(
                plot,
                row.author_id!,
                row.thread_id,
                readTimestamp
              );
            })
          )
      );
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    const affectedPriorityIds = new Set(
      dbActivities.map((a) => a.priority_id)
    );
    await plot.notifySyncDOs(affectedPriorityIds);

    // Return just the IDs for efficiency
    return dbActivities.map((dbActivity) => dbActivity.id as Uuid);
  } catch (error) {
    throw await handleDbOperationError(error, "createThreads", plot, {
      count: activities.length,
      has_any_source: activities.some((a) => "source" in a && !!a.source),
    });
  }
}

/**
 * Lists threads filed in a priority.
 * Requires ThreadAccess.Full.
 */
export async function getThreads(
  plot: Plot,
  options?: {
    priorityId?: Uuid;
    includeArchived?: boolean;
    limit?: number;
    offset?: number;
  }
): Promise<Thread[]> {
  const {
    priorityId,
    includeArchived = false,
    limit = 50,
    offset = 0,
  } = options ?? {};

  const effectivePriorityId =
    (priorityId as string | undefined) ?? (await plot.getRootPriorityId());
  await plot.validatePriorityAccess(effectivePriorityId);

  const clampedLimit = Math.min(Math.max(1, limit), 200);

  const userId = await plot.getUserId();

  let query = plot.db
    .selectFrom("user.thread")
    .selectAll("user.thread")
    .where("user_id", "=", userId)
    .where("priority_id", "=", effectivePriorityId as string);

  if (!includeArchived) {
    query = query.where("archived_at", "is", null);
  }

  query = query
    .orderBy("created_at", "desc")
    .limit(clampedLimit)
    .offset(offset);

  const rows = await query.execute();

  // Batch fetch tags for all threads
  const threadIds = rows.map((r) => r.id).filter(Boolean) as string[];
  const tagsMap = new Map<string, any>();
  if (threadIds.length > 0) {
    const tagsRows = await plot.db
      .selectFrom("thread_tags")
      .select(["thread_id", "tags"])
      .where("thread_id", "in", threadIds)
      .execute();
    for (const row of tagsRows) {
      if (row.thread_id) tagsMap.set(row.thread_id, row.tags);
    }
  }

  // Batch fetch priority info
  const priorityIds = [...new Set(rows.map((r) => r.priority_id).filter(Boolean))] as string[];
  const priorityMap = new Map<string, { id: string; title: string; archived_at: string | Date | null; key: string | null; color: number | null }>();
  if (priorityIds.length > 0) {
    const priorityRows = await plot.db
      .selectFrom("priority")
      .select(["id", "title", "archived_at", "key", "color"])
      .where("id", "in", priorityIds)
      .execute();
    for (const row of priorityRows) {
      priorityMap.set(row.id, row);
    }
  }

  return Promise.all(rows.map(async (data) => {
    const createdAtStr =
      data.created_at instanceof Date
        ? data.created_at.toISOString()
        : (data.created_at ?? new Date().toISOString());
    const updatedAtStr =
      data.updated_at instanceof Date
        ? data.updated_at.toISOString()
        : (data.updated_at ?? new Date().toISOString());

    const priorityInfo = priorityMap.get(data.priority_id as string);
    const thread = await fromDbThread(
      plot,
      // @ts-ignore - Kysely types vs fromDbThread expectations
      {
        ...data,
        id: data.id ?? "",
        created_at: createdAtStr,
        updated_at: updatedAtStr,
        created_by: (data as any).created_by ?? "",
        draft: data.draft ?? false,
        contacts: data.contacts ?? [],
        updated_by: data.updated_by ?? 0,
        sync_depth: null,
        tags: tagsMap.get(data.id as string) || null,
      }
    );

    // Enrich priority info from the batch fetch
    if (priorityInfo) {
      thread.focus = {
        id: priorityInfo.id as Uuid,
        title: priorityInfo.title ?? "Untitled",
        archived: priorityInfo.archived_at !== null,
        key: priorityInfo.key,
        color: priorityInfo.color,
        icon: null,
      };
    }

    return thread;
  }));
}

/** @deprecated Use createThread */
export const createActivity = createThread;
/** @deprecated Use updateThread */
export const updateActivity = updateThread;
/** @deprecated Use getThread */
export const getActivity = getThread;
/** @deprecated Use createThreads */
export const createActivities = createThreads;
