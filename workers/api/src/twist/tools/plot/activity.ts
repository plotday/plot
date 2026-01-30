import pLimit from "p-limit";

import { type Database, type Json, safeQuery } from "@plotday/db";
import { ActivityType } from "@plotday/twister/plot";
import {
  type Activity,
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
import {
  handleDbOperationError,
  prepareActivityForDb,
  processTagsActors,
  toDbRange,
} from "./activity-helpers";
import { fromDbActivity } from "./converters";
import { formatInterval } from "./datetime";
import type { Plot } from "./index";
import { createNotes, ensureIncreasingCreatedTimestamps } from "./note";
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
    const { priorityId, occurrences, ...prep } = await prepareActivityForDb(
      plot,
      activity
    );

    // Insert or upsert activity based on whether it has a source.
    let dbResult: {
      id: string;
      created_at: string;
      priority_id: string;
    };

    if ("upsert" in prep) {
      // Use database function for source-based upsert
      // RPC returns full activity row directly
      try {
        dbResult = safeQuery(
          await plot.supabase.rpc("upsert_activity", {
            p_activity: prep.upsert as Json,
            p_defaults: prep.defaults as Json,
          })
        );
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
      dbResult = safeQuery(
        await plot.supabase
          .from("activity")
          .insert(prep.insert)
          .select()
          .single()
      );
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
        const { error: upsertError } = await plot.supabase
          .from("activity_tag")
          .upsert(newTags, {
            onConflict: "actor_id,activity_id,occurrence,tag_id",
          });

        if (upsertError) {
          throw new Error(`Failed to upsert tags: ${upsertError.message}`);
        }
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
        }))
      );
    }

    // Mark as read for all priority users if unread is false
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    // Check both activity-level and occurrence-level unread flags
    const occurrencesHaveUnreadFalse =
      occurrences && occurrences.some((occ) => occ.unread === false);
    const shouldMarkAsRead =
      activity?.unread === false || occurrencesHaveUnreadFalse;

    if (shouldMarkAsRead) {
      // Get all users with access to this priority (including inherited access from parent priorities)
      const usersResult = await plot.supabase.rpc(
        "get_users_with_priority_access",
        {
          target_priority_id: priorityId,
        }
      );

      if (usersResult.data && usersResult.data.length > 0) {
        // Find the latest note timestamp for this activity, or use activity's created_at
        const latestNoteResult = await plot.supabase
          .from("note")
          .select("created_at")
          .eq("activity_id", dbResult.id)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        const latestTimestamp =
          latestNoteResult.data?.created_at ?? dbResult.created_at;

        // Create activity_read entries for all users with the latest timestamp
        const activityReadEntries = usersResult.data.map(
          (pu: { user_id: string }) => ({
            activity_id: dbResult.id,
            user_id: pu.user_id,
            read_at: latestTimestamp,
          })
        );

        const insertResult = await plot.supabase
          .from("activity_read")
          .upsert(activityReadEntries, { onConflict: "user_id,activity_id" });
        if (insertResult.error) {
          // Intentionally log but don't throw: activity_read is a non-critical feature that tracks
          // read status for notifications. Failing to mark as read should not prevent activity creation.
          // The activity was created successfully; the user will just see it as unread.
          const logger = createLogger({
            priority_twist_id: plot.priorityTwistId,
          });
          logger.error(
            "Failed to upsert activity_read entries",
            insertResult.error as Error,
            {
              activity_id: dbResult.id,
              count: activityReadEntries.length,
            }
          );
        }
      }
    }

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

export async function updateActivity(
  plot: Plot,
  activity: ActivityUpdate
): Promise<void> {
  try {
    // Determine activity ID - either provided directly or looked up by source
    let activityId: string;

    if ("id" in activity && activity.id) {
      // ID provided directly
      activityId = activity.id;
    } else if ("source" in activity && activity.source) {
      // Look up activity by source and priority root (composite unique key)
      const priorityRoot = await plot.getPriorityRoot();

      const { data: existingActivity, error: fetchError } = await plot.supabase
        .from("activity")
        .select("id")
        .eq("source", activity.source)
        .eq("source_priority_root", priorityRoot)
        .single();

      if (fetchError || !existingActivity) {
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
    }
    if (activity.meta !== undefined) {
      dbUpdate.meta = activity.meta;
    }

    // Handle recurrence fields
    if (activity.recurrenceRule !== undefined) {
      dbUpdate.recurrence_rule = activity.recurrenceRule;
    }
    if (activity.recurrenceExdates !== undefined) {
      dbUpdate.recurrence_exdates =
        activity.recurrenceExdates?.map((d) => d.toISOString()) ?? [];
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
      const { data: updatedActivity, error: updateError } = await plot.supabase
        .from("activity")
        .update(dbUpdate)
        .eq("id", activityId)
        .select("id")
        .single();

      if (updateError) {
        throw new Error(`Activity update failed: ${updateError.message}`);
      }

      if (!updatedActivity) {
        throw new Error(`Activity not found: ${activityId}`);
      }
    }

    // Handle full tags object replacement (only for activities created by this twist or another instance of the same twist)
    if (activity.tags !== undefined) {
      // Query for created_by and priority_id in a single query
      const { data: activityData, error: queryError } = await plot.supabase
        .from("activity")
        .select("created_by, priority_id")
        .eq("id", activityId)
        .single();

      if (queryError || !activityData) {
        throw new Error(
          `Failed to fetch activity: ${queryError?.message ?? "Not found"}`
        );
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
      const { error: deleteError } = await plot.supabase
        .from("activity_tag")
        .delete()
        .eq("activity_id", activityId);

      if (deleteError) {
        throw new Error(
          `Failed to delete existing tags: ${deleteError.message}`
        );
      }

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
        const { error: upsertError } = await plot.supabase
          .from("activity_tag")
          .upsert(newTags, {
            onConflict: "actor_id,activity_id,occurrence,tag_id",
          });

        if (upsertError) {
          throw new Error(`Failed to upsert new tags: ${upsertError.message}`);
        }
      }
    }

    // Handle twist tags separately using RPC (for adding/removing caller's own tags)
    // Note: RSVP tags (Attend/Skip/Undecided) are mutually exclusive -
    // the database function automatically removes conflicting RSVP tags.
    // Count tags can only be modified for the current user (enforced by RLS).
    if (activity.twistTags) {
      safeQuery(
        await plot.supabase.rpc("update_activity_tags", {
          p_activity_id: activityId,
          p_actor_id: plot.priorityTwistId,
          p_client_id: plot.getUpdatedBy(),
          p_tag_updates: activity.twistTags,
        })
      );
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
    // Query activities using the user_activity view
    // This view automatically filters to activities the user has access to
    let query = plot.supabase.from("user_activity").select(
      `
          *,
          author:actor!author_id(
            id,
            name,
            type,
            email,
            archived_at,
            avatar_url,
            created_at,
            updated_at
          ),
          assignee:actor!assignee_id(
            id,
            name,
            type,
            email,
            archived_at,
            avatar_url,
            created_at,
            updated_at
          )
        `
    );

    // Query by id or source (with priority root for source queries)
    if ("id" in activity) {
      query = query.eq("id", activity.id);
    } else {
      const priorityRoot = await plot.getPriorityRoot();
      query = query
        .eq("source", activity.source)
        .eq("source_priority_root", priorityRoot);
    }

    // Always include archived activities (no filter on archived_at)

    const { data, error } = await query.limit(1).maybeSingle();

    if (error) {
      throw error;
    }
    if (!data) {
      return null;
    }

    if (!data.author) {
      throw new Error(`Activity author not found`);
    }

    // Store data with non-null author for type safety
    // Add missing/nullable fields from the user_activity view with proper defaults
    // Note: user_activity view doesn't include source_priority_root or sync_depth columns
    const dataWithAuthor = {
      ...data,
      id: data.id ?? "",
      author_id: data.author_id ?? data.author.id ?? "",
      created_at: data.created_at ?? new Date().toISOString(),
      created_by: data.author_id ?? "",
      draft: data.draft ?? false,
      order: data.order ?? 0,
      priority_id: data.priority_id ?? "",
      private: data.private ?? false,
      type: (data.type ??
        "note") as Database["public"]["Enums"]["activity_type"],
      kind: (data as any).kind ?? null,
      updated_at: data.updated_at ?? new Date().toISOString(),
      updated_by: data.updated_by ?? 0,
      author: data.author,
      assignee: data.assignee ?? null,
      assignee_id: null,
      embedding: null,
      pick_priority: null,
      active_source: null,
      // Required by activity table Row type but not in user_activity view
      source_created_at: data.source_created_at ?? new Date().toISOString(),
      source_priority_root: null,
      sync_depth: null,
    };

    // Fetch tags for the activity
    const { data: tagsData } = data.id
      ? await plot.supabase
          .from("activity_tags")
          .select("tags")
          .eq("activity_id", data.id)
          .single()
      : { data: null };

    // Check if ContactAccess.Read permission is granted to include author email
    const includeAuthorEmail =
      plot.plotOptions?.contact?.access !== undefined &&
      plot.plotOptions.contact.access >= ContactAccess.Read;

    return fromDbActivity(
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
    const { data: exception, error: exceptionError } = await plot.supabase
      .from("activity_exception")
      .select("*")
      .eq("activity_id", activityId)
      .eq("occurrence", occurrenceStr)
      .maybeSingle();

    if (exceptionError) {
      throw exceptionError;
    }

    // Query for tags specific to this occurrence
    const { data: tagsData } = await plot.supabase
      .from("activity_tags")
      .select("tags")
      .eq("activity_id", activityId)
      .eq("occurrence", occurrenceStr)
      .maybeSingle();

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
      done: exception?.done_at ? new Date(exception.done_at) : activity.done,
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
    let query = plot.supabase.from("note").select(
      `
          id,
          created_at,
          source_created_at,
          updated_at,
          author_id,
          created_by,
          updated_by,
          archived_at,
          activity_id,
          draft,
          private,
          content,
          key,
          links,
          mentions,
          author:actor!author_id(
            id,
            name,
            type,
            email,
            archived_at,
            avatar_url,
            created_at,
            updated_at
          )
        `
    );

    // Query by id or key
    if ("id" in note) {
      query = query.eq("id", note.id);
    } else {
      query = query.eq("key", note.key);
    }

    // Always include archived notes (no filter on archived_at)

    const { data, error } = await query.limit(1).maybeSingle();

    if (error) {
      throw error;
    }
    if (!data) {
      return null;
    }

    if (!data.author) {
      throw new Error("Note author not found");
    }

    // Validate access to the priority via the activity
    // First fetch the activity to get the priority
    const { data: activityData, error: activityError } = await plot.supabase
      .from("activity")
      .select("priority_id")
      .eq("id", data.activity_id)
      .single();

    if (activityError || !activityData) {
      throw new Error(`Activity not found for note`);
    }

    await plot.validatePriorityAccess(activityData.priority_id);

    // Fetch the full activity for the note
    const activity = await getActivity(plot, { id: data.activity_id as Uuid });
    if (!activity) {
      throw new Error(`Activity not found for note`);
    }

    // Fetch tags for the note
    const { data: tagsData } = await plot.supabase
      .from("note_tags")
      .select("tags")
      .eq("note_id", data.id)
      .single();

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
        id: data.author.id as ActorId,
        type: (data.author.type ?? ActorType.Contact) as ActorType,
        name: data.author.name ?? null,
        email: includeAuthorEmail ? data.author.email ?? undefined : undefined,
      },
      private: data.private,
      archived: data.archived_at !== null,
      content: data.content,
      key: data.key || null,
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
    type ActivityRow = Database["public"]["Tables"]["activity"]["Row"];
    type DbActivity = Pick<ActivityRow, "id" | "priority_id" | "created_at">;
    const dbActivities: DbActivity[] = new Array(activities.length);

    const preparedActivities = await Promise.all(
      processedActivities.map((activity) =>
        limit(() => prepareActivityForDb(plot, activity))
      )
    );

    // Batch insert non-source activities
    const nonSourceResults = safeQuery(
      await plot.supabase
        .from("activity")
        .insert(
          preparedActivities
            .filter((pa) => "insert" in pa)
            .map((pa) => pa.insert)
        )
        .select("id, priority_id, created_at")
    ) as DbActivity[];

    // Upsert source-based activities
    let nonSourceIndex = 0;
    await Promise.all(
      preparedActivities.map((prepared, index) =>
        limit(async () => {
          if (!("upsert" in prepared)) {
            dbActivities[index] = nonSourceResults[nonSourceIndex++];
            return;
          }
          const { upsert, defaults } = prepared;
          const dbResult = safeQuery(
            await plot.supabase.rpc("upsert_activity", {
              p_activity: upsert as Json,
              p_defaults: defaults as Json,
            })
          );
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
      const { error: upsertError } = await plot.supabase
        .from("activity_tag")
        .upsert(allTags, {
          onConflict: "actor_id,activity_id,occurrence,tag_id",
        });

      if (upsertError) {
        throw new Error(`Failed to upsert tags: ${upsertError.message}`);
      }
    }

    // Create notes for all activities
    const allNotes: NewNote[] = processedActivities.flatMap(
      (activity, index) => {
        if (
          !("notes" in activity) ||
          !activity.notes ||
          activity.notes.length === 0
        ) {
          return [];
        }

        // Preprocess timestamps for this activity's notes before flattening
        // Cast is safe: helper only examines 'created' field, not 'activity'
        const processedActivityNotes = ensureIncreasingCreatedTimestamps(
          activity.notes as NewNote[]
        );

        return processedActivityNotes.map(
          (note): NewNote => ({
            ...note,
            activity: { id: dbActivities[index].id as Uuid },
          })
        );
      }
    );

    if (allNotes.length > 0) {
      // Notes already have timestamps assigned, but call createNotes which will
      // apply the function again (idempotent since notes now have created field)
      await createNotes(plot, allNotes);
    }

    // Mark activities as read for all priority users if unread === false
    // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
    const activitiesToMarkAsRead: Array<{
      dbActivity: DbActivity;
      originalActivity: NewActivity | NewActivityWithNotes;
    }> = [];

    for (let i = 0; i < activities.length; i++) {
      const originalActivity = activities[i];
      const occurrences = preparedActivities[i].occurrences;
      const occurrencesHaveUnreadFalse =
        occurrences &&
        occurrences.some((occ) => "unread" in occ && occ.unread === false);
      const shouldMarkAsRead =
        originalActivity?.unread === false || occurrencesHaveUnreadFalse;

      if (shouldMarkAsRead) {
        activitiesToMarkAsRead.push({
          dbActivity: dbActivities[i],
          originalActivity,
        });
      }
    }

    if (activitiesToMarkAsRead.length > 0) {
      // Get all activity IDs that need unread marking
      const activityIdsForUnread = activitiesToMarkAsRead.map(
        (a) => a.dbActivity.id
      );

      // Query latest note timestamps per activity AFTER notes are created
      const latestNotesResult = await plot.supabase
        .from("note")
        .select("activity_id, created_at")
        .in("activity_id", activityIdsForUnread)
        .order("created_at", { ascending: false });

      // Build map of activity_id -> latest timestamp
      const latestNoteTimestamps = new Map<string, string>();
      for (const note of latestNotesResult.data ?? []) {
        if (!latestNoteTimestamps.has(note.activity_id)) {
          latestNoteTimestamps.set(note.activity_id, note.created_at);
        }
      }

      // Group activities by priority_id to minimize database queries
      const activitiesByPriority = new Map<
        string,
        typeof activitiesToMarkAsRead
      >();
      for (const item of activitiesToMarkAsRead) {
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
              const usersResult = await plot.supabase.rpc(
                "get_users_with_priority_access",
                {
                  target_priority_id: priorityId,
                }
              );

              if (!usersResult.data || usersResult.data.length === 0) {
                return;
              }

              const activityReadEntries = priorityActivities.flatMap((item) =>
                usersResult.data!.map((pu: { user_id: string }) => ({
                  activity_id: item.dbActivity.id,
                  user_id: pu.user_id,
                  // Use latest note timestamp if available, otherwise fall back to activity's created_at
                  read_at:
                    latestNoteTimestamps.get(item.dbActivity.id) ??
                    item.dbActivity.created_at,
                }))
              );

              if (activityReadEntries.length === 0) {
                return;
              }

              const insertResult = await plot.supabase
                .from("activity_read")
                .upsert(activityReadEntries, {
                  onConflict: "user_id,activity_id",
                });
              if (insertResult.error) {
                // Intentionally log but don't throw: activity_read is a non-critical feature that tracks
                // read status for notifications. Failing to mark as read should not prevent activity creation.
                // The activities were created successfully; users will just see them as unread.
                const logger = createLogger({
                  priority_twist_id: plot.priorityTwistId,
                });
                logger.error(
                  "Failed to upsert activity_read entries for batch activities",
                  insertResult.error,
                  {
                    count: activityReadEntries.length,
                  }
                );
              }
            })
        )
      );
    }

    // Return just the IDs for efficiency
    return dbActivities.map((dbActivity) => dbActivity.id as Uuid);
  } catch (error) {
    handleDbOperationError(error, "createActivities", plot.priorityTwistId, {
      count: activities.length,
      has_any_source: activities.some((a) => "source" in a && !!a.source),
    });
  }
}
