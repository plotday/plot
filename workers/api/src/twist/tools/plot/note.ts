import { type Database, safeQuery } from "@plotday/db";
import {
  type Activity,
  type ActivityLink,
  type ActorId,
  type ActorType,
  type NewNote,
  type Note,
  type NoteUpdate,
  type Tag,
  type Uuid,
} from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";

import { createLogger } from "@plotday/worker-util";
import { truncateUuidForUpdatedBy } from "../../../utils/uuid";
import {
  convertNoteToMarkdown,
  handleDbOperationError,
  processNewActor,
  processNewActorArray,
} from "./activity-helpers";
import type { Plot } from "./index";

/**
 * Ensures notes have strictly increasing sourceCreatedAt timestamps.
 * Notes with explicit created field keep it, notes without get assigned
 * incrementally increasing timestamps based on array position.
 */
export function ensureIncreasingCreatedTimestamps(notes: NewNote[]): NewNote[] {
  if (notes.length === 0) return notes;

  let lastTimestamp = Date.now();

  return notes.map((note) => {
    if (note.created) {
      // Note has explicit timestamp - use it and update tracking
      const noteTime =
        note.created instanceof Date
          ? note.created.getTime()
          : new Date(note.created).getTime();
      lastTimestamp = Math.max(lastTimestamp, noteTime);
      return note;
    } else {
      // Note lacks timestamp - assign next incremental value
      lastTimestamp += 1; // 1ms increment
      return {
        ...note,
        created: new Date(lastTimestamp),
      };
    }
  });
}

export async function createNote(
  plot: Plot,
  note: NewNote,
  skipActivityRead = false
): Promise<Uuid> {
  try {
    // Skip fully empty notes (no content, no links, no mentions)
    const isEmpty =
      (!note.content || note.content.trim() === "") &&
      (!note.links || note.links.length === 0) &&
      (!note.mentions || note.mentions.length === 0);

    if (isEmpty) {
      // Return a minimal Note object without database insertion
      // This maintains the function signature while avoiding empty note creation
      throw new Error(
        "Cannot create fully empty note (no content, links, or mentions)"
      );
    }

    // Resolve activity ID - either provided directly or looked up by source
    let activityId: string;

    if ("id" in note.activity) {
      // ID provided directly
      activityId = note.activity.id;
    } else if ("source" in note.activity) {
      // Look up activity by source and priority root (composite unique key)
      const priorityRoot = await plot.getPriorityRoot();
      const { data: existingActivity, error: fetchError } = await plot.supabase
        .from("activity")
        .select("id")
        .eq("source", note.activity.source)
        .eq("source_priority_root", priorityRoot)
        .single();

      if (fetchError || !existingActivity) {
        throw new Error(
          `Activity not found with source "${note.activity.source}": ${
            fetchError?.message ?? "Not found"
          }`
        );
      }

      activityId = existingActivity.id;
    } else {
      throw new Error("Note activity must provide either id or source");
    }

    // Fetch activity with author for validation and later use
    const { data: activityData, error: activityError } = await plot.supabase
      .from("activity")
      .select(
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
      )
      .eq("id", activityId)
      .single();

    if (activityError) {
      throw new Error(`Activity not found: ${activityError.message}`);
    }

    if (!activityData.author) {
      throw new Error(`Activity author not found`);
    }

    // Skip priority access validation for notes - activities may have been moved
    // after creation and the twist should still be able to add notes

    // Convert note content to markdown if needed
    let contentToStore = note.content;
    if (note.content && note.contentType && note.contentType !== "markdown") {
      contentToStore = await convertNoteToMarkdown(
        plot.env.AI,
        note.content,
        note.contentType
      );
    }

    // Process author - use provided author or default to twist
    const authorId = note.author
      ? await processNewActor(plot, note.author, activityData.priority_id)
      : plot.priorityTwistId;

    // Process mentions if provided - convert NewActor[] to ActorId[]
    let mentionIds: ActorId[] | null = null;
    if (note.mentions) {
      mentionIds = await processNewActorArray(
        plot,
        note.mentions,
        activityData.priority_id
      );
    }

    // Convert Note to database format
    // IMPORTANT: For webhook-originated notes (notes with authors), use the author's ID
    // as updated_by so the activity update appears in priority_twist_activity_update view.
    // The view filters out updates where updated_by equals the twist to prevent loops,
    // but webhook notes represent external changes that should trigger sync.
    const dbNote: any = {
      author_id: authorId,
      created_by: plot.priorityTwistId,
      activity_id: activityId,
      source_created_at:
        note.created?.toISOString() ?? new Date().toISOString(),
      draft: false,
      private: note.private ?? false,
      content: contentToStore,
      links: note.links ?? null,
      mentions: mentionIds,
      updated_by: note.author
        ? truncateUuidForUpdatedBy(authorId as string)
        : plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      // Default to un-archived for upserts unless archived is explicitly specified
      archived_at: note.archived ? new Date().toISOString() : null,
    };

    // If tool provided an ID, use it instead of letting database generate one
    if ("id" in note && note.id) {
      dbNote.id = note.id;
    }

    // If tool provided a key, add it for upsert behavior
    if ("key" in note && note.key) {
      dbNote.key = note.key;
    }

    // Insert or upsert note based on whether key is provided
    // When key is provided, use upsert to handle duplicate keys within same activity
    const dbResult = safeQuery(
      dbNote.key
        ? await plot.supabase
            .from("note")
            .upsert(dbNote, { onConflict: "activity_id,key" })
            .select()
            .single()
        : await plot.supabase.from("note").insert(dbNote).select().single()
    );

    // Mark activity as read for all priority users if unread is false
    // Skip if called from batch operations to avoid deadlock from parallel upserts
    if (!skipActivityRead && note?.unread === false) {
      // Get all users with access to this priority (including inherited access from parent priorities)
      const usersResult = await plot.supabase.rpc(
        "get_users_with_priority_access",
        {
          target_priority_id: activityData.priority_id,
        }
      );

      if (usersResult.data && usersResult.data.length > 0) {
        // Create or update activity_read entries for all users
        const activityReadEntries = usersResult.data.map(
          (pu: { user_id: string }) => ({
            activity_id: activityId,
            user_id: pu.user_id,
            read_at: dbResult.created_at, // Use note's created_at timestamp
          })
        );

        // Use upsert to handle cases where some users may have already read the activity
        const upsertResult = await plot.supabase
          .from("activity_read")
          .upsert(activityReadEntries, {
            onConflict: "user_id,activity_id",
          });
        if (upsertResult.error) {
          const logger = createLogger({
            priority_twist_id: plot.priorityTwistId,
          });
          logger.error(
            "Failed to upsert activity_read entries for note",
            upsertResult.error as Error,
            {
              activity_id: activityId,
              count: activityReadEntries.length,
            }
          );
        }
      }
    }

    // Process tags if provided - convert NewActor[] to ActorId[] for each tag
    let processedTags: Partial<Record<number, ActorId[]>> | null = null;
    if (note.tags) {
      processedTags = {};
      for (const [tagId, newActors] of Object.entries(note.tags)) {
        if (newActors && newActors.length > 0) {
          const actorIds = await processNewActorArray(
            plot,
            newActors,
            activityData.priority_id
          );
          if (actorIds.length > 0) {
            processedTags[parseInt(tagId)] = actorIds;
          }
        }
      }
    }

    // Add tags if provided
    if (processedTags) {
      // Insert tags using note_tag table
      const tagInserts = Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            note_id: dbResult.id,
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (tagInserts.length > 0) {
        safeQuery(await plot.supabase.from("note_tag").insert(tagInserts));
      }
    }

    // Return just the ID for efficiency
    return dbResult.id as Uuid;
  } catch (error) {
    handleDbOperationError(error, "createNote", plot.priorityTwistId, {
      activity_id: "id" in note.activity ? note.activity.id : undefined,
      has_key: "key" in note && !!note.key,
      has_content: !!note.content,
      has_links: !!note.links?.length,
    });
  }
}

export async function createNotes(
  plot: Plot,
  notes: NewNote[]
): Promise<Uuid[]> {
  // Ensure notes without created timestamps get strictly increasing values
  const processedNotes = ensureIncreasingCreatedTimestamps(notes);

  // Create all notes in parallel, filtering out empty notes
  // Pass skipActivityRead: true to avoid deadlock from parallel activity_read upserts
  const results = await Promise.allSettled(
    processedNotes.map((note) => createNote(plot, note, true))
  );

  // Return only successfully created note IDs, log failures (except empty note errors)
  const noteIds = results
    .map((result, _index) => {
      if (result.status === "fulfilled") {
        return result.value;
      } else {
        // Only log non-empty-note errors
        if (!result.reason?.message?.includes("fully empty note")) {
          const logger = createLogger({ component: "plot_tool" });
          logger.error("Failed to create note", result.reason);
        }
        return null;
      }
    })
    .filter((id): id is Uuid => id !== null);

  return noteIds;
}

export async function updateNote(plot: Plot, note: NoteUpdate): Promise<void> {
  try {
    // Determine note ID - either provided directly or looked up by key
    let noteId: string;

    if ("id" in note && note.id) {
      // ID provided directly
      noteId = note.id;
    } else if ("key" in note && note.key) {
      // Look up note by key
      // Note: We need the activity_id to look up by key, but NoteUpdate doesn't require it
      // We'll need to query by key alone since the unique constraint is (activity_id, key)
      // This means if the same key exists in multiple activities, this will fail
      const { data: existingNote, error: fetchError } = await plot.supabase
        .from("note")
        .select("id")
        .eq("key", note.key)
        .single();

      if (fetchError || !existingNote) {
        throw new Error(
          `Note not found with key "${note.key}": ${
            fetchError?.message ?? "Not found"
          }`
        );
      }

      noteId = existingNote.id;
    } else {
      throw new Error("Note update must provide either id or key");
    }

    // Validate access to the note's activity
    const { data: noteData, error: noteError } = await plot.supabase
      .from("note")
      .select("activity_id")
      .eq("id", noteId)
      .single();

    if (noteError) {
      throw new Error(`Note not found: ${noteError.message}`);
    }

    // Validate access to the activity's priority
    const { data: activityData, error: activityError } = await plot.supabase
      .from("activity")
      .select("priority_id")
      .eq("id", noteData.activity_id)
      .single();

    if (activityError) {
      throw new Error(`Activity not found: ${activityError.message}`);
    }

    // Skip priority access validation for notes - activities may have been moved
    // after creation and the twist should still be able to update notes

    // Build update object
    const dbUpdate: Database["public"]["Tables"]["note"]["Update"] = {
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
    };

    // Handle basic fields
    if (note.content !== undefined) {
      // Convert note content to markdown if needed
      if (note.content && note.contentType && note.contentType !== "markdown") {
        dbUpdate.content = await convertNoteToMarkdown(
          plot.env.AI,
          note.content,
          note.contentType
        );
      } else {
        dbUpdate.content = note.content;
      }
    }
    if (note.links !== undefined) {
      dbUpdate.links = note.links;
    }
    if (note.private !== undefined) {
      dbUpdate.private = note.private;
    }
    if (note.archived !== undefined) {
      dbUpdate.archived_at = note.archived ? new Date().toISOString() : null;
    }
    if (note.mentions !== undefined) {
      // Process mentions - convert NewActor[] to ActorId[]
      if (note.mentions === null) {
        dbUpdate.mentions = null;
      } else {
        const mentionIds = await processNewActorArray(
          plot,
          note.mentions,
          activityData.priority_id
        );
        dbUpdate.mentions = mentionIds.length > 0 ? mentionIds : null;
      }
    }

    // Check if there are meaningful updates (beyond updated_by, sync_depth)
    const meaningfulKeys = Object.keys(dbUpdate).filter(
      (key) => !["updated_by", "sync_depth"].includes(key)
    );
    const hasMeaningfulUpdates = meaningfulKeys.length > 0;

    // Execute the update only if there are meaningful changes
    if (hasMeaningfulUpdates) {
      const { data: updatedNote, error: updateError } = await plot.supabase
        .from("note")
        .update(dbUpdate)
        .eq("id", noteId)
        .select("id")
        .single();

      if (updateError) {
        throw new Error(`Note update failed: ${updateError.message}`);
      }

      if (!updatedNote) {
        throw new Error(`Note not found: ${noteId}`);
      }
    }

    // Handle tags if provided
    if (note.tags !== undefined) {
      // Delete all existing tags for this note
      const { error: deleteError } = await plot.supabase
        .from("note_tag")
        .delete()
        .eq("note_id", noteId);

      if (deleteError) {
        throw new Error(
          `Failed to delete existing tags: ${deleteError.message}`
        );
      }

      // Process tags - convert NewActor[] to ActorId[] for each tag
      const processedTags: Partial<Record<number, ActorId[]>> = {};
      for (const [tagId, newActors] of Object.entries(note.tags)) {
        if (newActors && newActors.length > 0) {
          const actorIds = await processNewActorArray(
            plot,
            newActors,
            activityData.priority_id
          );
          if (actorIds.length > 0) {
            processedTags[parseInt(tagId)] = actorIds;
          }
        }
      }

      // Insert new tags
      const newTags = Object.entries(processedTags)
        .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
        .flatMap(([tagId, actorIds]) =>
          actorIds!.map((actorId) => ({
            note_id: noteId,
            tag_id: parseInt(tagId),
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          }))
        );

      if (newTags.length > 0) {
        const { error: insertError } = await plot.supabase
          .from("note_tag")
          .insert(newTags);

        if (insertError) {
          throw new Error(`Failed to insert new tags: ${insertError.message}`);
        }
      }
    }
  } catch (error) {
    handleDbOperationError(error, "updateNote", plot.priorityTwistId, {
      has_note_id: "id" in note && !!note.id,
      has_key: "key" in note && !!note.key,
      update_fields: Object.keys(note).filter((k) => k !== "id" && k !== "key"),
    });
  }
}

export async function getNotes(
  plot: Plot,
  activity: Activity
): Promise<Note[]> {
  try {
    // Validate access to the priority
    await plot.validatePriorityAccess(activity.priority.id);

    // Get all notes for this activity
    const { data, error } = await plot.supabase
      .from("note")
      .select(
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
      )
      .eq("activity_id", activity.id)
      .order("created_at", { ascending: true });

    if (error) {
      const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
      logger.error("Failed to get notes", error as Error, {
        activity_id: activity.id,
      });
      throw error;
    }

    // Fetch tags for all notes
    const noteIds = data.map((row: any) => row.id);
    const { data: tagsData } = await plot.supabase
      .from("note_tags")
      .select("note_id, tags")
      .in("note_id", noteIds);

    // Create a map of note_id to tags
    const tagsMap = new Map<string, any>();
    if (tagsData) {
      for (const tagRecord of tagsData) {
        if (tagRecord.note_id) {
          tagsMap.set(tagRecord.note_id, tagRecord.tags);
        }
      }
    }

    // Check if ContactAccess.Read permission is granted to include author email
    const includeAuthorEmail =
      plot.plotOptions?.contact?.access !== undefined &&
      plot.plotOptions.contact.access >= ContactAccess.Read;

    return data.map((row) => {
      if (!row.author) {
        throw new Error("Note author not found");
      }
      return {
        // @ts-ignore - row.id is a string from DB, but Uuid is a branded type
        id: row.id as any,
        created: row.source_created_at
          ? new Date(row.source_created_at)
          : new Date(row.created_at),
        activity: activity, // Use the activity parameter passed to the function
        author: {
          id: row.author.id as ActorId,
          type: row.author.type as unknown as ActorType,
          name: row.author.name ?? null,
          email: includeAuthorEmail ? row.author.email ?? undefined : undefined,
        },
        private: row.private,
        archived: row.archived_at !== null,
        content: row.content,
        key: row.key || null,
        links: row.links as ActivityLink[] | null,
        mentions: (row.mentions as string[])?.map((m) => m as ActorId) ?? [],
        tags:
          (tagsMap.get(row.id) as Partial<Record<Tag, ActorId[]>> | null) || {},
      };
    });
  } catch (err) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Failed to get notes", err as Error);
    throw err;
  }
}
