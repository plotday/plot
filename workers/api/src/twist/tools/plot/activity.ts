import pLimit from "p-limit";

import { type Database, type Json } from "@plotday/db";
import { ActivityType } from "@plotday/twister/plot";
import {
  type Activity,
  type ActivityFilter,
  type ActivityLink,
  type ActivityMeta,
  type ActivityOccurrence,
  type ActivityUpdate,
  type ActorId,
  ActorType,
  type NewActivity,
  type NewActivityWithNotes,
  type NewNote,
  type Note,
  type Tag,
  type Tags,
  type Uuid,
} from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";

import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";
import { rpc, rpcUser } from "../../../rpc";
import {
  handleDbOperationError,
  markActivityReadForAuthor,
  prepareActivityForDb,
  processTagsActors,
  toDbRange,
} from "./activity-helpers";
import { fromDbActivity } from "./converters";
import { formatInterval } from "./datetime";
import type { Plot } from "./index";
import {
  createNotes,
  ensureIncreasingCreatedTimestamps,
} from "./note";
import { processOccurrences } from "./occurrences";

/**
 * Ensures activities have strictly increasing sourceCreatedAt timestamps.
 * Activities with explicit created field keep it, activities without get assigned
 * incrementally increasing timestamps based on array position.
 */
function ensureIncreasingActivityCreatedTimestamps(
  activities: (NewActivity | NewActivityWithNotes)[]
): (NewActivity | NewActivityWithNotes)[] {
  if (activities.length === 0) return activities;

  let lastTimestamp = Date.now();

  return activities.map((activity) => {
    if (activity.created) {
      // Activity has explicit timestamp - use it and update tracking
      const activityTime =
        activity.created instanceof Date
          ? activity.created.getTime()
          : new Date(activity.created).getTime();
      lastTimestamp = Math.max(lastTimestamp, activityTime);
      return activity;
    } else {
      // Activity lacks timestamp - assign next incremental value
      lastTimestamp += 1; // 1ms increment
      return {
        ...activity,
        created: new Date(lastTimestamp),
      };
    }
  });
}

// Re-export from split files
export { createNote, createNotes, getNotes, updateNote } from "./note";
export { createActivityException, processOccurrences } from "./occurrences";
export {
  actorTypeToString,
  convertNoteToMarkdown,
  createPreviewFromMarkdown,
  markActivityReadForAuthor,
  prepareActivityForDb,
  processNewActor,
  processNewActorArray,
  processTagsActors,
  type PreparedActivity,
} from "./activity-helpers";

export async function createActivity(
  plot: Plot,
  activity: NewActivity | NewActivityWithNotes
): Promise<Uuid> {
  try {
    // Use shared helper for all preparation logic
    const { priorityId, authorId, occurrences, ...prep } =
      await prepareActivityForDb(plot, activity);

    // Insert or upsert activity based on whether it has a source.
    let dbResult: {
      id: string;
      created_at: string | Date;
      source_created_at: string | Date;
      priority_id: string;
    };

    if ("upsert" in prep) {
      // Use database function for source-based upsert
      // RPC returns full activity row directly
      try {
        const userId = await plot.getUserId();
        dbResult = await rpcUser(plot.db, "upsert_activity", {
          user_id: userId,
          p_activity: prep.upsert as Json,
          p_defaults: prep.defaults as Json,
        });
      } catch (error) {
        const logger = createLogger({ component: "plot_tool" });
        logger.error("upsert_activity failed", error as Error, {
          upsert: JSON.stringify(prep.upsert),
          defaults: JSON.stringify(prep.defaults),
        });
        throw error;
      }
    } else {
      // Plain insert for activities without source
      dbResult = await plot.db
        .insertInto("activity")
        // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
        .values(prep.insert)
        .returningAll()
        .executeTakeFirstOrThrow();
    }

    // Process occurrences after insert/upsert (for field overrides and tags)
    if (occurrences.length > 0) {
      await processOccurrences(plot, dbResult.id, occurrences, priorityId);
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
            activity_id: dbResult.id,
            occurrence: null, // Series-level tags for regular activities
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (newTags.length > 0) {
        await plot.db
          .insertInto("activity_tag")
          .values(newTags)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "activity_id", "occurrence", "tag_id"])
              .doUpdateSet((eb) => ({
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Create initial notes if provided
    if ("notes" in activity && activity.notes && activity.notes.length > 0) {
      await createNotes(
        plot,
        activity.notes.map((note) => ({
          ...note,
          // dbResult.id is a string from the database, but NewNote.activity.id expects a branded Uuid type.
          // The cast is safe because database IDs are valid UUIDs.
          activity: { id: dbResult.id as Uuid },
        })),
        { priority_id: priorityId }
      );
    }

    // Mark as read based on unread flag:
    // - false: mark read for ALL priority users (initial sync)
    // - undefined/omitted: mark read for author only if they are the twist owner
    // - true: explicitly unread for all (do nothing)
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    const occurrencesHaveUnreadFalse =
      occurrences && occurrences.some((occ) => occ.unread === false);
    const shouldMarkAllAsRead =
      activity?.unread === false || occurrencesHaveUnreadFalse;

    if (shouldMarkAllAsRead) {
      // Mark read for ALL priority users
      // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
      // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
      const usersData = await rpc(plot.db, "get_users_with_priority_access", {
        target_priority_id: priorityId,
      });
      const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];

      if (userIds.length > 0) {
        const latestNoteRow = await plot.db
          .selectFrom("note")
          .select("source_created_at")
          .where("activity_id", "=", dbResult.id)
          .orderBy("source_created_at", "desc")
          .limit(1)
          .executeTakeFirst();

        const dbSourceCreatedAt =
          dbResult.source_created_at instanceof Date
            ? dbResult.source_created_at.toISOString()
            : dbResult.source_created_at;
        const noteSourceCreatedAt =
          latestNoteRow?.source_created_at instanceof Date
            ? latestNoteRow.source_created_at.toISOString()
            : latestNoteRow?.source_created_at;
        const latestTimestamp = noteSourceCreatedAt ?? dbSourceCreatedAt;

        const activityReadEntries = userIds.map(
          (userId) => ({
            activity_id: dbResult.id,
            user_id: userId,
            read_at: latestTimestamp,
          })
        );

        try {
          await plot.db
            .insertInto("activity_read")
            .values(activityReadEntries)
            .onConflict((oc) =>
              oc
                .columns(["user_id", "activity_id"])
                .doUpdateSet((eb) => ({
                  read_at: eb.ref("excluded.read_at"),
                }))
            )
            .execute();
        } catch (err) {
          const logger = createLogger({
            priority_twist_id: plot.priorityTwistId,
          });
          logger.error(
            "Failed to upsert activity_read entries",
            err as Error,
            {
              activity_id: dbResult.id,
              count: activityReadEntries.length,
            }
          );
        }
      }
    } else if (activity?.unread === undefined) {
      // Default: mark read for the activity author and each note author
      const latestNoteRow = await plot.db
        .selectFrom("note")
        .select("source_created_at")
        .where("activity_id", "=", dbResult.id)
        .orderBy("source_created_at", "desc")
        .limit(1)
        .executeTakeFirst();

      const dbSourceCreatedAt2 =
        dbResult.source_created_at instanceof Date
          ? dbResult.source_created_at.toISOString()
          : dbResult.source_created_at;
      const noteSourceCreatedAt2 =
        latestNoteRow?.source_created_at instanceof Date
          ? latestNoteRow.source_created_at.toISOString()
          : latestNoteRow?.source_created_at;
      const readTimestamp = noteSourceCreatedAt2 ?? dbSourceCreatedAt2;

      // Mark read for the activity's author
      await markActivityReadForAuthor(
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
        .where("note.activity_id", "=", dbResult.id)
        .where("note.author_id", "is not", null)
        .where("note.author_id", "!=", authorId)
        .where("note.author_id", "!=", plot.priorityTwistId)
        .where("contact.user_id", "is not", null)
        .execute();

      for (const row of noteAuthors) {
        if (row.author_id) {
          await markActivityReadForAuthor(
            plot,
            row.author_id,
            dbResult.id,
            readTimestamp
          );
        }
      }
    }
    // unread === true: do nothing (explicitly unread for all)

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    await plot.notifySyncDOs(new Set([priorityId]));

    // Return just the ID for efficiency
    return dbResult.id as Uuid;
  } catch (error) {
    handleDbOperationError(error, "createActivity", plot.priorityTwistId, {
      activity_type: activity.type,
      has_notes: "notes" in activity && !!activity.notes?.length,
      has_source: "source" in activity && !!activity.source,
      has_occurrences:
        "occurrences" in activity && !!activity.occurrences?.length,
      has_id: "id" in activity && !!activity.id,
    });
  }
}

async function updateActivitiesByMatch(
  plot: Plot,
  activity: ActivityUpdate & { match: ActivityFilter }
): Promise<void> {
  const { match } = activity;

  // Filter to activities created by this twist instance
  let query = plot.db
    .updateTable("activity")
    .where("created_by", "=", plot.priorityTwistId);

  // Apply meta filter using jsonb containment
  if (match.meta) {
    query = query.where(
      sql<boolean>`meta @> ${JSON.stringify(match.meta)}::jsonb`
    );
  }

  // Apply type filter
  if (match.type !== undefined) {
    let dbType: string;
    switch (match.type) {
      case ActorType.User:
        dbType = "note";
        break;
      case ActorType.Contact:
        dbType = "action";
        break;
      case ActorType.Twist:
        dbType = "event";
        break;
      default:
        throw new Error(`Unknown activity type in filter: ${match.type}`);
    }
    // @ts-ignore - type column is an enum
    query = query.where("type", "=", dbType);
  }

  // Build update object - only scalar fields for bulk updates
  const dbUpdate: Database["public"]["Tables"]["activity"]["Update"] = {
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
  };

  if (activity.archived !== undefined) {
    dbUpdate.archived_at = activity.archived
      ? new Date().toISOString()
      : null;
  }
  if (activity.done !== undefined) {
    dbUpdate.done_at = activity.done ? activity.done.toISOString() : null;
    if (activity.done && activity.type === undefined) {
      dbUpdate.type = "action";
    }
  }
  if (activity.type !== undefined) {
    switch (activity.type) {
      case ActivityType.Note:
        dbUpdate.type = "note";
        break;
      case ActivityType.Action:
        dbUpdate.type = "action";
        break;
      case ActivityType.Event:
        dbUpdate.type = "event";
        break;
    }
  }
  if (activity.title !== undefined) {
    dbUpdate.title =
      activity.title && activity.title.trim() !== "" ? activity.title : null;
  }
  if (activity.private !== undefined) {
    dbUpdate.private = activity.private;
  }
  if (activity.meta !== undefined) {
    dbUpdate.meta = activity.meta;
  }
  if (activity.kind !== undefined) {
    dbUpdate.kind = activity.kind;
  }
  if (activity.order !== undefined) {
    dbUpdate.order = activity.order;
  }

  // Check if there are meaningful updates
  const meaningfulKeys = Object.keys(dbUpdate).filter(
    (key) => !["updated_by", "sync_depth"].includes(key)
  );
  if (meaningfulKeys.length === 0) {
    return;
  }

  // Execute bulk update, returning affected priority IDs for sync notification
  const results = await query
    // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
    .set(dbUpdate)
    .returning("priority_id")
    .execute();

  // Notify sync DOs for affected priorities
  if (results.length > 0) {
    const affectedPriorityIds = new Set(results.map((r) => r.priority_id));
    await plot.notifySyncDOs(affectedPriorityIds);
  }
}

export async function updateActivity(
  plot: Plot,
  activity: ActivityUpdate
): Promise<void> {
  try {
    // Handle bulk update by match filter
    if ("match" in activity && activity.match) {
      return updateActivitiesByMatch(plot, activity as ActivityUpdate & { match: ActivityFilter });
    }

    // Determine activity ID - either provided directly or looked up by source
    let activityId: string;

    if ("id" in activity && activity.id) {
      // ID provided directly
      activityId = activity.id;
    } else if ("source" in activity && activity.source) {
      // Look up activity by source and priority root (composite unique key)
      const priorityRoot = await plot.getPriorityRoot();

      const existingActivity = await plot.db
        .selectFrom("activity")
        .select("id")
        .where("source", "=", activity.source)
        .where("source_priority_root", "=", priorityRoot)
        .executeTakeFirst();

      if (!existingActivity) {
        throw new Error(`Activity not found for source: ${activity.source}`);
      }
      activityId = existingActivity.id;
    } else {
      throw new Error("Activity update must provide either id or source");
    }

    // Build update object
    const dbUpdate: Database["public"]["Tables"]["activity"]["Update"] = {
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
    };

    // Handle type mapping if provided
    if (activity.type !== undefined) {
      switch (activity.type) {
        case ActivityType.Note:
          dbUpdate.type = "note";
          break;
        case ActivityType.Action:
          dbUpdate.type = "action";
          break;
        case ActivityType.Event:
          dbUpdate.type = "event";
          break;
      }
    }

    // Handle basic fields
    if (activity.title !== undefined) {
      dbUpdate.title =
        activity.title && activity.title.trim() !== "" ? activity.title : null;
    }
    if (activity.private !== undefined) {
      dbUpdate.private = activity.private;
    }
    if (activity.archived !== undefined) {
      dbUpdate.archived_at = activity.archived
        ? new Date().toISOString()
        : null;
    }
    if (activity.done !== undefined) {
      dbUpdate.done_at = activity.done ? activity.done.toISOString() : null;
      // Only actions can have done_at — auto-set type if not already provided
      if (activity.done && activity.type === undefined) {
        dbUpdate.type = "action";
      }
    }
    if (activity.meta !== undefined) {
      dbUpdate.meta = activity.meta;
    }
    if (activity.order !== undefined) {
      dbUpdate.order = activity.order;
    }

    // Handle recurrence fields
    if (activity.recurrenceRule !== undefined) {
      dbUpdate.recurrence_rule = activity.recurrenceRule;
    }
    if (activity.recurrenceExdates !== undefined) {
      dbUpdate.recurrence_exdates =
        activity.recurrenceExdates?.map((d) => d.toISOString()) ?? [];
    }
    // Handle incremental add/remove of recurrence exdates
    const addExdates = (activity as any).addRecurrenceExdates as
      | Date[]
      | undefined;
    const removeExdates = (activity as any).removeRecurrenceExdates as
      | Date[]
      | undefined;
    if (
      (addExdates !== undefined || removeExdates !== undefined) &&
      activity.recurrenceExdates === undefined
    ) {
      // Read current exdates from the database
      const currentActivity = await plot.db
        .selectFrom("activity")
        .select("recurrence_exdates")
        .where("id", "=", activityId)
        .executeTakeFirstOrThrow();

      const existing = (currentActivity.recurrence_exdates ?? []).map((d) =>
        d instanceof Date ? d.toISOString() : String(d)
      );
      const addSet = new Set(
        addExdates?.map((d) => d.toISOString()) ?? []
      );
      const removeSet = new Set(
        removeExdates?.map((d) => d.toISOString()) ?? []
      );

      // Merge: existing + add, then subtract remove, deduplicated
      const merged = [...new Set([...existing, ...addSet])]
        .filter((d) => !removeSet.has(d))
        .sort();

      dbUpdate.recurrence_exdates = merged;
    }
    // Handle scheduling fields - need to calculate dbEnd and duration
    const hasSchedulingUpdate =
      activity.start !== undefined ||
      activity.end !== undefined ||
      activity.recurrenceUntil !== undefined ||
      activity.recurrenceCount !== undefined;

    if (hasSchedulingUpdate) {
      const range = toDbRange(
        activity.start ?? null,
        activity.end ?? null,
        activity.recurrenceUntil ?? null,
        activity.recurrenceCount ?? undefined,
        activity.recurrenceRule ?? null
      );
      if (range.at !== undefined) dbUpdate.at = range.at;
      if (range.on !== undefined) dbUpdate.on = range.on;
      if (range.duration !== undefined) {
        dbUpdate.duration =
          range.duration !== null ? formatInterval(range.duration) : null;
      }
    }

    // For actions with null assignee, force at and on to null (constraint requirement)
    // This handles updates that explicitly set assignee_id to null
    if ("assignee_id" in dbUpdate && dbUpdate.assignee_id === null) {
      const hadScheduling =
        ("at" in dbUpdate && dbUpdate.at !== null) ||
        ("on" in dbUpdate && dbUpdate.on !== null);
      dbUpdate.at = null;
      dbUpdate.on = null;
      if (hadScheduling) {
        console.warn(
          "[updateActivity] Update with null assignee_id had scheduling fields - nullifying at/on to satisfy constraint"
        );
      }
    }

    // Check if there are meaningful updates (beyond updated_by, sync_depth, occurrence)
    const meaningfulKeys = Object.keys(dbUpdate).filter(
      (key) => !["updated_by", "sync_depth", "occurrence"].includes(key)
    );
    const hasMeaningfulUpdates = meaningfulKeys.length > 0;

    // Execute the update only if there are meaningful changes
    if (hasMeaningfulUpdates) {
      const updatedActivity = await plot.db
        .updateTable("activity")
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
      // Query for created_by and priority_id in a single query
      const activityData = await plot.db
        .selectFrom("activity")
        .select(["created_by", "priority_id"])
        .where("id", "=", activityId)
        .executeTakeFirst();

      if (!activityData) {
        throw new Error("Failed to fetch activity: Not found");
      }
      const { created_by: createdBy, priority_id: priorityId } = activityData;

      // Check if activity was created by this exact instance (fast path)
      const isExactInstance = createdBy === plot.priorityTwistId;
      // Or check if activity was created by another instance of the same twist (fallback)
      const isSameTwist =
        !isExactInstance &&
        createdBy &&
        (await plot.isSameTwistDefinition(createdBy));

      if (!isExactInstance && !isSameTwist) {
        throw new Error(
          `Cannot update tags field: activity was not created by this twist (activity.createdBy: ${createdBy}, twist: ${plot.priorityTwistId}). Use twistTags instead to add/remove tags for this twist.`
        );
      }

      // Delete all existing tags for this activity
      await plot.db
        .deleteFrom("activity_tag")
        .where("activity_id", "=", activityId)
        .execute();

      // Process tags - convert NewActor[] to ActorId[] for each tag (batched)
      const processedTags = await processTagsActors(
        plot,
        activity.tags,
        priorityId
      );

      // Insert new tags
      // Note: This updates series-level tags (occurrence=null)
      // For occurrence-specific tags, use NewActivity.occurrences field
      const newTags = Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            activity_id: activityId,
            occurrence: null, // Series-level tags
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (newTags.length > 0) {
        await plot.db
          .insertInto("activity_tag")
          .values(newTags)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "activity_id", "occurrence", "tag_id"])
              .doUpdateSet((eb) => ({
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Handle twist tags separately using RPC (for adding/removing caller's own tags)
    // Note: RSVP tags (Attend/Skip/Undecided) are mutually exclusive -
    // the database function automatically removes conflicting RSVP tags.
    // Count tags can only be modified for the current user (enforced by RLS).
    if (activity.twistTags) {
      const userId = await plot.getUserId();
      await rpcUser(plot.db, "update_activity_tags", {
        user_id: userId,
        p_activity_id: activityId,
        p_actor_id: plot.priorityTwistId,
        p_client_id: plot.getUpdatedBy(),
        p_tag_updates: activity.twistTags,
      });
    }

    // Process occurrences if provided (for recurring activities)
    if (
      "occurrences" in activity &&
      activity.occurrences &&
      activity.occurrences.length > 0
    ) {
      await processOccurrences(
        plot,
        activityId,
        activity.occurrences,
        plot.priorityId
      );
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    await plot.notifySyncDOs(new Set([plot.priorityId]));
  } catch (error) {
    handleDbOperationError(error, "updateActivity", plot.priorityTwistId, {
      has_activity_id: "id" in activity && !!activity.id,
      has_source: "source" in activity && !!activity.source,
      update_fields: Object.keys(activity).filter(
        (k) => k !== "id" && k !== "source"
      ),
    });
  }
}

export async function getActivity(
  plot: Plot,
  activity: { id: Uuid } | { source: string }
): Promise<Activity | null> {
  try {
    // Query activities using the user.activity view
    // Filter to activities the user has access to
    let activityId: string | undefined;

    // Query by id or source (with priority root for source queries)
    if ("id" in activity) {
      activityId = activity.id;
    } else {
      // source_priority_root is not in the user.activity view, so look up the id first
      const priorityRoot = await plot.getPriorityRoot();
      const found = await plot.db
        .selectFrom("activity")
        .select("id")
        .where("source", "=", activity.source)
        .where("source_priority_root", "=", priorityRoot)
        .executeTakeFirst();
      activityId = found?.id;
    }

    if (!activityId) {
      return null;
    }

    // Always include archived activities (no filter on archived_at)

    const userId = await plot.getUserId();
    const data = await plot.db
      .selectFrom("user.activity")
      .selectAll("user.activity")
      .where("user_id", "=", userId)
      .where("id", "=", activityId)
      .limit(1)
      .executeTakeFirst();

    if (!data) {
      return null;
    }

    // Fetch author and assignee separately
    const author = data.author_id
      ? await plot.db
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
          .executeTakeFirst()
      : null;

    if (!author) {
      throw new Error(`Activity author not found`);
    }

    const assignee = data.assignee_id
      ? await plot.db
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
          .where("id", "=", data.assignee_id)
          .executeTakeFirst() ?? null
      : null;

    // Store data with non-null author for type safety
    // Add missing/nullable fields from the user.activity view with proper defaults
    // Note: user.activity view doesn't include source_priority_root or sync_depth columns
    // Kysely returns Date objects for timestamp columns, convert to ISO strings
    const createdAtStr =
      data.created_at instanceof Date
        ? data.created_at.toISOString()
        : (data.created_at ?? new Date().toISOString());
    const updatedAtStr =
      data.updated_at instanceof Date
        ? data.updated_at.toISOString()
        : (data.updated_at ?? new Date().toISOString());
    const sourceCreatedAtStr =
      data.source_created_at instanceof Date
        ? data.source_created_at.toISOString()
        : (data.source_created_at ?? new Date().toISOString());

    const dataWithAuthor = {
      ...data,
      id: data.id ?? "",
      author_id: data.author_id ?? author.id ?? "",
      created_at: createdAtStr,
      created_by: data.author_id ?? "",
      draft: data.draft ?? false,
      order: data.order ?? 0,
      priority_id: data.priority_id ?? "",
      private: data.private ?? false,
      type: (data.type ??
        "note") as Database["public"]["Enums"]["activity_type"],
      kind: (data as any).kind ?? null,
      updated_at: updatedAtStr,
      updated_by: data.updated_by ?? 0,
      // `actor` required by Database Row type (supabase relation), point to author
      actor: author,
      author: author,
      assignee: assignee ?? null,
      assignee_id: null,
      embedding: null,
      pick_priority: null,
      active_source: null,
      // Required by activity table Row type but not in user.activity view
      source_created_at: sourceCreatedAtStr,
      source_priority_root: null,
      sync_depth: null,
    };

    // Fetch tags for the activity
    const tagsData = data.id
      ? await plot.db
          .selectFrom("activity_tags")
          .select("tags")
          .where("activity_id", "=", data.id)
          .executeTakeFirst()
      : null;

    // Check if ContactAccess.Read permission is granted to include author email
    const includeAuthorEmail =
      plot.plotOptions?.contact?.access !== undefined &&
      plot.plotOptions.contact.access >= ContactAccess.Read;

    return fromDbActivity(
      // @ts-ignore - Kysely returns Date for timestamp columns, but fromDbActivity expects Supabase Row types with string timestamps
      {
        ...dataWithAuthor,
        tags: tagsData?.tags || null,
      },
      includeAuthorEmail
    );
  } catch (err) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Failed to get activity", err as Error);
    throw err;
  }
}

export async function getActivityOccurrence(
  plot: Plot,
  activityId: Uuid,
  occurrence: Date | string
): Promise<ActivityOccurrence | null> {
  try {
    // First get the base activity
    const activity = await getActivity(plot, { id: activityId });
    if (!activity) {
      return null;
    }

    // Format occurrence as YYYY-MM-DD or YYYY-MM-DDTHH:MM
    const occurrenceDate =
      occurrence instanceof Date ? occurrence : new Date(occurrence);
    const hasTimestamp = activity.start instanceof Date;
    const occurrenceStr = hasTimestamp
      ? occurrenceDate.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
      : occurrenceDate.toISOString().substring(0, 10); // YYYY-MM-DD

    // Query for the activity_exception for this occurrence
    const exception = await plot.db
      .selectFrom("activity_exception")
      .selectAll()
      .where("activity_id", "=", activityId)
      .where("occurrence", "=", occurrenceStr)
      .executeTakeFirst();

    // Query for tags specific to this occurrence
    const tagsData = await plot.db
      .selectFrom("activity_tags")
      .select("tags")
      .where("activity_id", "=", activityId)
      .where("occurrence", "=", occurrenceStr)
      .executeTakeFirst();

    // Helper to parse PostgreSQL range types
    const parseRange = (
      rangeStr: unknown
    ): { start: string; end: string } | null => {
      if (!rangeStr || typeof rangeStr !== "string") return null;
      const match = rangeStr.match(/^\[([^,]+),([^)]+)\)/);
      if (!match) return null;
      return { start: match[1], end: match[2] };
    };

    // Parse start/end from exception if present
    let occurrenceStart: Date | string = activity.start ?? occurrenceDate;
    let occurrenceEnd: Date | string | null = activity.end;

    if (exception) {
      const atRange = parseRange(exception.at);
      const onRange = parseRange(exception.on);

      if (atRange) {
        occurrenceStart = new Date(atRange.start);
        occurrenceEnd = new Date(atRange.end);
      } else if (onRange) {
        occurrenceStart = onRange.start;
        occurrenceEnd = onRange.end;
      }
    }

    // Build the occurrence response
    // Start with base activity fields, then override with exception fields if they exist
    const occurrenceResponse: ActivityOccurrence = {
      occurrence: occurrenceDate,
      activity: activity,
      start: occurrenceStart,
      end: occurrenceEnd,
      done: exception?.done_at ? new Date(exception.done_at) : activity.type === ActivityType.Action ? activity.done : null,
      title: exception?.title ?? activity.title,
      meta: (exception?.meta as ActivityMeta | null) ?? activity.meta,
      tags: (tagsData?.tags as Tags) || activity.tags,
      archived:
        exception?.archived_at !== null && exception?.archived_at !== undefined
          ? true
          : activity.archived,
    };

    return occurrenceResponse;
  } catch (err) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Failed to get activity occurrence", err as Error);
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
        "activity_id",
        "draft",
        "private",
        "content",
        "key",
        "links",
        "mentions",
        "re_note_id",
      ]);

    // Query by id or key
    if ("id" in note) {
      query = query.where("id", "=", note.id);
    } else {
      query = query.where("key", "=", note.key);
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
    const activityData = await plot.db
      .selectFrom("activity")
      .select("priority_id")
      .where("id", "=", data.activity_id)
      .executeTakeFirst();

    if (!activityData) {
      throw new Error(`Activity not found for note`);
    }

    await plot.validatePriorityAccess(activityData.priority_id);

    // Fetch the full activity for the note
    const activity = await getActivity(plot, { id: data.activity_id as Uuid });
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
      activity: activity,
      author: {
        id: author.id as ActorId,
        type: (author.type ?? ActorType.Contact) as ActorType,
        name: author.name ?? null,
        email: includeAuthorEmail ? author.email ?? undefined : undefined,
      },
      private: data.private,
      archived: data.archived_at !== null,
      content: data.content,
      key: data.key || null,
      reNote: data.re_note_id ? { id: data.re_note_id as Uuid } : null,
      links: data.links as ActivityLink[] | null,
      mentions: (data.mentions as string[])?.map((m) => m as ActorId) ?? [],
      tags: (tagsData?.tags as Partial<Record<Tag, ActorId[]>> | null) || {},
    };
  } catch (err) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Failed to get note", err as Error);
    throw err;
  }
}

export async function createActivities(
  plot: Plot,
  activities: (NewActivity | NewActivityWithNotes)[]
): Promise<Uuid[]> {
  if (activities.length === 0) {
    return [];
  }

  try {
    // Ensure activities without created timestamps get strictly increasing values
    const processedActivities =
      ensureIncreasingActivityCreatedTimestamps(activities);

    const limit = pLimit(5);
    type DbActivity = { id: string; priority_id: string; created_at: string | Date; source_created_at: string | Date };
    const dbActivities: DbActivity[] = new Array(activities.length);

    const preparedActivities = await Promise.all(
      processedActivities.map((activity) =>
        limit(() => prepareActivityForDb(plot, activity))
      )
    );

    // Batch insert non-source activities
    const nonSourceInserts = preparedActivities
      .filter((pa) => "insert" in pa)
      .map((pa) => pa.insert);

    const nonSourceResults =
      nonSourceInserts.length > 0
        ? await plot.db
            .insertInto("activity")
            // @ts-ignore - Database types define `at` as `unknown` but Kysely expects specific types
            .values(nonSourceInserts)
            .returning(["id", "priority_id", "created_at", "source_created_at"])
            .execute()
        : ([] as DbActivity[]);

    // Upsert source-based activities
    let nonSourceIndex = 0;
    const userId = await plot.getUserId();
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          if (!("upsert" in prepared)) {
            dbActivities[index] = nonSourceResults[nonSourceIndex++];
            return;
          }
          const { upsert, defaults } = prepared;
          const dbResult = await rpcUser(plot.db, "upsert_activity", {
            user_id: userId,
            p_activity: upsert as Json,
            p_defaults: defaults as Json,
          });
          dbActivities[index] = dbResult as DbActivity;
        })
      )
    );

    // Process occurrences
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          const { occurrences, priorityId } = prepared;
          if (occurrences && occurrences.length > 0) {
            await processOccurrences(
              plot,
              dbActivities[index].id,
              occurrences,
              priorityId
            );
          }
        })
      )
    );

    // Process series-level tags for all activities
    const processedTagsArray: Array<Partial<Record<number, ActorId[]>> | null> =
      new Array(activities.length);

    await Promise.all(
      activities.map((activity, index) =>
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
            activity_id: dbActivity.id,
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
        .insertInto("activity_tag")
        .values(allTags)
        .onConflict((oc) =>
          oc
            .columns(["actor_id", "activity_id", "occurrence", "tag_id"])
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
    for (let index = 0; index < processedActivities.length; index++) {
      const activity = processedActivities[index];
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
          activity: { id: dbActivities[index].id as Uuid },
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
      await createNotes(plot, notes, { priority_id: priorityId });
    }

    // Mark activities as read based on unread flag:
    // - false: mark read for ALL priority users (initial sync)
    // - undefined/omitted: mark read for author only if they are the twist owner
    // - true: explicitly unread for all (do nothing)
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    const activitiesToMarkAllAsRead: Array<{
      dbActivity: DbActivity;
      originalActivity: NewActivity | NewActivityWithNotes;
    }> = [];
    const activitiesToMarkAuthorAsRead: Array<{
      dbActivity: DbActivity;
      authorId: string;
    }> = [];

    for (let i = 0; i < activities.length; i++) {
      const originalActivity = activities[i];
      const occurrences = preparedActivities[i].occurrences;
      const occurrencesHaveUnreadFalse =
        occurrences &&
        occurrences.some((occ) => "unread" in occ && occ.unread === false);
      const shouldMarkAllAsRead =
        originalActivity?.unread === false || occurrencesHaveUnreadFalse;

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
      // Get all activity IDs that need unread marking for all users
      const activityIdsForUnread = activitiesToMarkAllAsRead.map(
        (a) => a.dbActivity.id
      );

      // Query latest note timestamps per activity AFTER notes are created
      const latestNotesRows = await plot.db
        .selectFrom("note")
        .select(["activity_id", "source_created_at"])
        .where("activity_id", "in", activityIdsForUnread)
        .orderBy("source_created_at", "desc")
        .execute();

      // Build map of activity_id -> latest timestamp (as ISO string)
      const latestNoteTimestamps = new Map<string, string>();
      for (const noteRow of latestNotesRows) {
        if (!latestNoteTimestamps.has(noteRow.activity_id)) {
          const ts =
            noteRow.source_created_at instanceof Date
              ? noteRow.source_created_at.toISOString()
              : noteRow.source_created_at;
          latestNoteTimestamps.set(noteRow.activity_id, ts);
        }
      }

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

      // For each priority, get users and create activity_read entries
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

              const activityReadEntries = priorityActivities.flatMap((item) => {
                const fallback =
                  item.dbActivity.source_created_at instanceof Date
                    ? item.dbActivity.source_created_at.toISOString()
                    : item.dbActivity.source_created_at;
                return userIds.map((userId) => ({
                  activity_id: item.dbActivity.id,
                  user_id: userId,
                  read_at:
                    latestNoteTimestamps.get(item.dbActivity.id) ?? fallback,
                }));
              });

              if (activityReadEntries.length === 0) {
                return;
              }

              try {
                await plot.db
                  .insertInto("activity_read")
                  .values(activityReadEntries)
                  .onConflict((oc) =>
                    oc
                      .columns(["user_id", "activity_id"])
                      .doUpdateSet((eb) => ({
                        read_at: eb.ref("excluded.read_at"),
                      }))
                  )
                  .execute();
              } catch (err) {
                const logger = createLogger({
                  priority_twist_id: plot.priorityTwistId,
                });
                logger.error(
                  "Failed to upsert activity_read entries for batch activities",
                  err as Error,
                  {
                    count: activityReadEntries.length,
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

      // Query latest note timestamps for these activities
      const latestNotesRows = await plot.db
        .selectFrom("note")
        .select(["activity_id", "source_created_at"])
        .where("activity_id", "in", authorActivityIds)
        .orderBy("source_created_at", "desc")
        .execute();

      const latestNoteTimestamps = new Map<string, string>();
      for (const noteRow of latestNotesRows) {
        if (!latestNoteTimestamps.has(noteRow.activity_id)) {
          const ts =
            noteRow.source_created_at instanceof Date
              ? noteRow.source_created_at.toISOString()
              : noteRow.source_created_at;
          latestNoteTimestamps.set(noteRow.activity_id, ts);
        }
      }

      await Promise.all(
        activitiesToMarkAuthorAsRead.map((item) =>
          limit(async () => {
            const fallback =
              item.dbActivity.source_created_at instanceof Date
                ? item.dbActivity.source_created_at.toISOString()
                : item.dbActivity.source_created_at;
            const readTimestamp =
              latestNoteTimestamps.get(item.dbActivity.id) ?? fallback;
            await markActivityReadForAuthor(
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
          new Set([item.authorId, plot.priorityTwistId]),
        ])
      );

      const noteAuthorRows = await plot.db
        .selectFrom("note")
        .innerJoin("contact", "contact.id", "note.author_id")
        .select(["note.activity_id", "note.author_id"])
        .distinct()
        .where("note.activity_id", "in", authorActivityIds)
        .where("note.author_id", "is not", null)
        .where("note.author_id", "!=", plot.priorityTwistId)
        .where("contact.user_id", "is not", null)
        .execute();

      await Promise.all(
        noteAuthorRows
          .filter((row) => {
            const excluded = authorIdsByActivity.get(row.activity_id);
            return row.author_id && (!excluded || !excluded.has(row.author_id));
          })
          .map((row) =>
            limit(async () => {
              const fallback =
                activitiesToMarkAuthorAsRead.find(
                  (item) => item.dbActivity.id === row.activity_id
                )?.dbActivity.source_created_at;
              const fallbackStr =
                fallback instanceof Date
                  ? fallback.toISOString()
                  : fallback ?? new Date().toISOString();
              const readTimestamp =
                latestNoteTimestamps.get(row.activity_id) ?? fallbackStr;
              await markActivityReadForAuthor(
                plot,
                row.author_id!,
                row.activity_id,
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
    handleDbOperationError(error, "createActivities", plot.priorityTwistId, {
      count: activities.length,
      has_any_source: activities.some((a) => "source" in a && !!a.source),
    });
  }
}
