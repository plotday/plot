import type { Database } from "@plotday/db";
import {
  type Action,
  type ActorId,
  type ActorType,
  type NewNote,
  type Note,
  type NoteUpdate,
  type Tag,
  type Thread,
  type Uuid,
} from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";

import { rpc } from "../../../rpc";
import type { Plot } from "./index";
import {
  convertNoteToMarkdown,
  handleDbOperationError,
  markThreadReadForAuthor,
  processNewActor,
  processNewActorArray,
} from "./thread-helpers";

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

/**
 * Context from a caller that already has the activity data,
 * avoiding a redundant SELECT in createNote.
 */
export type ActivityContext = {
  priority_id: string;
  created_by?: string;
};

export async function createNote(
  plot: Plot,
  note: NewNote,
  skipActivityRead = false,
  activityContext?: ActivityContext,
  skipNotify = false
): Promise<Uuid> {
  try {
    // Skip fully empty notes (no content, no links, no mentions)
    const isEmpty =
      (!note.content || note.content.trim() === "") &&
      (!note.actions || note.actions.length === 0) &&
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

    if ("id" in note.thread) {
      // ID provided directly
      activityId = note.thread.id;
    } else if ("source" in note.thread) {
      // Look up activity by source and priority root via the link table
      const priorityRoot = await plot.getPriorityRoot();
      const existingLink = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source", "=", note.thread.source)
        .where("source_priority_root", "=", priorityRoot)
        .executeTakeFirst();

      if (!existingLink || !existingLink.thread_id) {
        throw new Error(
          `Activity not found with source "${note.thread.source}": Not found`
        );
      }

      activityId = existingLink.thread_id;
    } else {
      throw new Error("Note activity must provide either id or source");
    }

    // Use provided context or fetch activity data from the database.
    // When called from createActivity/createActivities, the caller already has
    // priority_id, so we skip this query to avoid a redundant round-trip.
    let priorityId: string;
    let threadCreatedBy: string | null = null;
    if (activityContext) {
      priorityId = activityContext.priority_id;
      if (activityContext.created_by) {
        threadCreatedBy = activityContext.created_by;
      } else {
        // Fallback: fetch created_by for auto-mention logic
        const threadRow = await plot.db
          .selectFrom("thread")
          .select("created_by")
          .where("id", "=", activityId)
          .executeTakeFirst();
        threadCreatedBy = threadRow?.created_by ?? null;
      }
    } else {
      const activityData = await plot.db
        .selectFrom("thread")
        .select(["priority_id", "created_by"])
        .where("id", "=", activityId)
        .executeTakeFirst();

      if (!activityData) {
        throw new Error(`Activity not found: ${activityId}`);
      }

      priorityId = activityData.priority_id;
      threadCreatedBy = activityData.created_by;
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
      ? await processNewActor(plot, note.author, priorityId)
      : plot.priorityTwistId;

    // Process mentions if provided - convert NewActor[] to ActorId[]
    let mentionIds: ActorId[] | null = null;
    if (note.mentions) {
      mentionIds = await processNewActorArray(plot, note.mentions, priorityId);
    }

    // Auto-mention the calling twist so it stays routed for future notes
    if (mentionIds === null) mentionIds = [];
    if (!mentionIds.includes(plot.priorityTwistId as ActorId)) {
      mentionIds.push(plot.priorityTwistId as ActorId);
    }

    // Auto-mention the thread-creating twist (if different from calling twist)
    // so the thread creator continues to receive notes
    if (threadCreatedBy && threadCreatedBy !== plot.priorityTwistId) {
      const isCreatorTwist = await plot.db
        .selectFrom("priority_twist")
        .select("id")
        .where("id", "=", threadCreatedBy)
        .executeTakeFirst();
      if (isCreatorTwist && !mentionIds.includes(threadCreatedBy as ActorId)) {
        mentionIds.push(threadCreatedBy as ActorId);
      }
    }

    // Convert Note to database format
    const dbNote: any = {
      author_id: authorId,
      created_by: plot.priorityTwistId,
      thread_id: activityId,
      source_created_at:
        note.created?.toISOString() ?? new Date().toISOString(),
      draft: false,
      private: note.private ?? false,
      content: contentToStore,
      actions: note.actions ? JSON.stringify(note.actions) : null,
      mentions: mentionIds,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      // Default to un-archived for upserts unless archived is explicitly specified
      archived_at: note.archived ? new Date().toISOString() : null,
      re_note_id: note.reNote && "id" in note.reNote ? note.reNote.id : null,
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
    const dbResult = dbNote.key
      ? await plot.db
          .insertInto("note")
          .values(dbNote)
          .onConflict((oc) =>
            oc.columns(["thread_id", "key"]).doUpdateSet((eb) => ({
              author_id: eb.ref("excluded.author_id"),
              created_by: eb.ref("excluded.created_by"),
              source_created_at: eb.ref("excluded.source_created_at"),
              draft: eb.ref("excluded.draft"),
              private: eb.ref("excluded.private"),
              content: eb.ref("excluded.content"),
              actions: eb.ref("excluded.actions"),
              mentions: eb.ref("excluded.mentions"),
              updated_by: eb.ref("excluded.updated_by"),
              sync_depth: eb.ref("excluded.sync_depth"),
              archived_at: eb.ref("excluded.archived_at"),
              re_note_id: eb.ref("excluded.re_note_id"),
            }))
          )
          .returningAll()
          .executeTakeFirstOrThrow()
      : await plot.db
          .insertInto("note")
          .values(dbNote)
          .returningAll()
          .executeTakeFirstOrThrow();

    // Generate embedding (best-effort, don't fail the create)
    if (
      contentToStore &&
      contentToStore.trim().length > 0 &&
      (await plot.isAiEnabled())
    ) {
      const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
      try {
        const embedding = await plot.ai.embed(contentToStore);
        await plot.db
          .updateTable("note")
          .set({ embedding: JSON.stringify(embedding) })
          .where("id", "=", dbResult.id)
          .execute();
      } catch (error) {
        logger.warn("Failed to generate note embedding", {
          note_id: dbResult.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    // Mark activity as read based on unread flag:
    // - false: mark read for ALL priority users (initial sync)
    // - undefined/omitted: mark read for author only if they are the twist owner
    // - true: explicitly unread for all (do nothing)
    // Skip if called from batch operations to avoid deadlock from parallel upserts
    if (!skipActivityRead && note?.unread === false) {
      // Mark read for ALL priority users
      // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
      // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
      const usersResult = await rpc(plot.db, "get_users_with_priority_access", {
        target_priority_id: priorityId,
      });

      const userIds = (Array.isArray(usersResult)
        ? usersResult
        : usersResult
        ? [usersResult]
        : []) as unknown as string[];
      if (userIds.length > 0) {
        const activityReadEntries = userIds.map((userId) => ({
          thread_id: activityId,
          user_id: userId,
          read_at: dbResult.source_created_at,
        }));

        try {
          await plot.db
            .insertInto("thread_read")
            .values(activityReadEntries)
            .onConflict((oc) =>
              oc.columns(["user_id", "thread_id"]).doUpdateSet((eb) => ({
                read_at: eb.ref("excluded.read_at"),
              }))
            )
            .execute();
        } catch (upsertError) {
          const logger = createLogger({
            priority_twist_id: plot.priorityTwistId,
          });
          logger.error(
            "Failed to upsert activity_read entries for note",
            upsertError as Error,
            {
              thread_id: activityId,
              count: activityReadEntries.length,
            }
          );
        }
      }
    } else if (!skipActivityRead && note?.unread === undefined) {
      // Default: mark read for just the author if they are the twist owner
      await markThreadReadForAuthor(
        plot,
        authorId as string,
        activityId,
        dbResult.source_created_at instanceof Date
          ? dbResult.source_created_at.toISOString()
          : dbResult.source_created_at
      );
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
            priorityId
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
        await plot.db.insertInto("note_tag").values(tagInserts).execute();
      }
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    if (!skipNotify) {
      await plot.notifySyncDOs(new Set([priorityId]));
    }

    // Return just the ID for efficiency
    return dbResult.id as Uuid;
  } catch (error) {
    handleDbOperationError(error, "createNote", plot.priorityTwistId, {
      thread_id: "id" in note.thread ? note.thread.id : undefined,
      has_key: "key" in note && !!note.key,
      has_content: !!note.content,
      has_links: !!note.actions?.length,
    });
  }
}

export async function createNotes(
  plot: Plot,
  notes: NewNote[],
  activityContext?: ActivityContext
): Promise<Uuid[]> {
  // Ensure notes without created timestamps get strictly increasing values
  const processedNotes = ensureIncreasingCreatedTimestamps(notes);

  // Create all notes in parallel, filtering out empty notes
  // Pass skipActivityRead: true to avoid deadlock from parallel activity_read upserts
  // Pass skipNotify: true to batch-notify once after all notes are created
  const results = await Promise.allSettled(
    processedNotes.map((note) =>
      createNote(plot, note, true, activityContext, true)
    )
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

  // Resolve reNote key references → re_note_id for notes that specified a key-based reply
  const notesNeedingKeyResolution = processedNotes
    .map((note, index) => ({ note, index }))
    .filter(
      ({ note, index }) =>
        note.reNote &&
        "key" in note.reNote &&
        results[index].status === "fulfilled"
    );

  if (notesNeedingKeyResolution.length > 0) {
    // Resolve the activity ID from the first note
    let activityId: string | undefined;
    const firstNote = processedNotes[0];
    if ("id" in firstNote.thread) {
      activityId = firstNote.thread.id;
    } else if ("source" in firstNote.thread) {
      const priorityRoot = await plot.getPriorityRoot();
      const data = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source", "=", firstNote.thread.source)
        .where("source_priority_root", "=", priorityRoot)
        .executeTakeFirst();
      activityId = data?.thread_id ?? undefined;
    }

    if (activityId) {
      // Batch lookup: all referenced keys in this activity
      const keys = notesNeedingKeyResolution.map(
        ({ note }) => (note.reNote as { key: string }).key
      );
      const keyNotes = await plot.db
        .selectFrom("note")
        .select(["id", "key"])
        .where("thread_id", "=", activityId)
        .where("key", "in", keys)
        .execute();

      if (keyNotes.length > 0) {
        const keyToId = new Map(keyNotes.map((n) => [n.key, n.id]));

        for (const { note, index } of notesNeedingKeyResolution) {
          const parentId = keyToId.get((note.reNote as { key: string }).key);
          const noteId = (results[index] as PromiseFulfilledResult<Uuid>).value;
          if (parentId && noteId) {
            await plot.db
              .updateTable("note")
              .set({ re_note_id: parentId })
              .where("id", "=", noteId)
              .execute();
          }
        }
      }
    }
  }

  // Notify sync DOs once for the batch (unless called from createActivities which notifies itself)
  if (!activityContext) {
    await plot.notifySyncDOs(new Set([plot.priorityId]));
  }

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
      const existingNote = await plot.db
        .selectFrom("note")
        .select("id")
        .where("key", "=", note.key)
        .executeTakeFirst();

      if (!existingNote) {
        throw new Error(`Note not found with key "${note.key}": Not found`);
      }

      noteId = existingNote.id;
    } else {
      throw new Error("Note update must provide either id or key");
    }

    // Validate access to the note's activity
    const noteData = await plot.db
      .selectFrom("note")
      .select("thread_id")
      .where("id", "=", noteId)
      .executeTakeFirst();

    if (!noteData) {
      throw new Error(`Note not found: ${noteId}`);
    }

    // Validate access to the activity's priority
    const activityData = await plot.db
      .selectFrom("thread")
      .select("priority_id")
      .where("id", "=", noteData.thread_id)
      .executeTakeFirst();

    if (!activityData) {
      throw new Error(`Activity not found: ${noteData.thread_id}`);
    }

    const priorityId = activityData.priority_id;

    // Skip priority access validation for notes - activities may have been moved
    // after creation and the twist should still be able to update notes

    // Build update object (cast needed because @plotday/db types halfvec as unknown)
    const dbUpdate: Omit<
      Database["public"]["Tables"]["note"]["Update"],
      "embedding"
    > = {
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
    if (note.actions !== undefined) {
      dbUpdate.actions = note.actions
        ? JSON.stringify(note.actions)
        : note.actions;
    }
    if (note.private !== undefined) {
      dbUpdate.private = note.private;
    }
    if (note.archived !== undefined) {
      dbUpdate.archived_at = note.archived ? new Date().toISOString() : null;
    }
    if (note.reNote !== undefined) {
      dbUpdate.re_note_id =
        note.reNote && "id" in note.reNote ? note.reNote.id : null;
    }
    if (note.mentions !== undefined) {
      // Process mentions - convert NewActor[] to ActorId[]
      if (note.mentions === null) {
        dbUpdate.mentions = null;
      } else {
        const mentionIds = await processNewActorArray(
          plot,
          note.mentions,
          priorityId
        );
        dbUpdate.mentions = mentionIds.length > 0 ? mentionIds : null;
      }
    }

    // When identified by id, key is an updatable field (sets the note's key for future upsert matching)
    if (
      "id" in note &&
      (note as { id: string; key?: string }).key !== undefined
    ) {
      dbUpdate.key = (note as { id: string; key?: string }).key!;
    }

    // Check if there are meaningful updates (beyond updated_by, sync_depth)
    const meaningfulKeys = Object.keys(dbUpdate).filter(
      (key) => !["updated_by", "sync_depth"].includes(key)
    );
    const hasMeaningfulUpdates = meaningfulKeys.length > 0;

    // Execute the update only if there are meaningful changes
    if (hasMeaningfulUpdates) {
      const updatedNote = await plot.db
        .updateTable("note")
        .set(dbUpdate)
        .where("id", "=", noteId)
        .returning("id")
        .executeTakeFirst();

      if (!updatedNote) {
        throw new Error(`Note not found: ${noteId}`);
      }
    }

    // Update embedding if content changed and AI is enabled
    if (
      note.content !== undefined &&
      hasMeaningfulUpdates &&
      (await plot.isAiEnabled())
    ) {
      const contentForEmbed = dbUpdate.content as string | null;
      const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
      if (contentForEmbed && contentForEmbed.trim().length > 0) {
        try {
          const embedding = await plot.ai.embed(contentForEmbed);
          await plot.db
            .updateTable("note")
            .set({ embedding: JSON.stringify(embedding) })
            .where("id", "=", noteId)
            .execute();
        } catch (error) {
          logger.warn("Failed to update note embedding", {
            note_id: noteId,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }
    }

    // Handle tags if provided
    if (note.tags !== undefined) {
      // Delete all existing tags for this note
      await plot.db
        .deleteFrom("note_tag")
        .where("note_id", "=", noteId)
        .execute();

      // Process tags - convert NewActor[] to ActorId[] for each tag
      const processedTags: Partial<Record<number, ActorId[]>> = {};
      for (const [tagId, newActors] of Object.entries(note.tags)) {
        if (newActors && newActors.length > 0) {
          const actorIds = await processNewActorArray(
            plot,
            newActors,
            priorityId
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
        await plot.db.insertInto("note_tag").values(newTags).execute();
      }
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    await plot.notifySyncDOs(new Set([priorityId]));
  } catch (error) {
    handleDbOperationError(error, "updateNote", plot.priorityTwistId, {
      has_note_id: "id" in note && !!note.id,
      has_key: "key" in note && !!note.key,
      update_fields: Object.keys(note).filter((k) => k !== "id" && k !== "key"),
    });
  }
}

export async function getNotes(plot: Plot, activity: Thread): Promise<Note[]> {
  try {
    // Validate access to the priority
    await plot.validatePriorityAccess(activity.priority.id);

    // Get all notes for this activity
    const rows = await plot.db
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
        "private",
        "content",
        "key",
        "actions",
        "mentions",
        "re_note_id",
      ])
      .where("thread_id", "=", activity.id)
      .orderBy("created_at", "asc")
      .execute();

    // Fetch all unique author actors in one query
    const authorIds = [...new Set(rows.map((r) => r.author_id))];
    const authors =
      authorIds.length > 0
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
            .where("id", "in", authorIds)
            .execute()
        : [];
    const authorMap = new Map(authors.map((a) => [a.id, a]));

    // Fetch tags for all notes
    const noteIds = rows.map((row) => row.id);
    const tagsData =
      noteIds.length > 0
        ? await plot.db
            .selectFrom("note_tags")
            .select(["note_id", "tags"])
            .where("note_id", "in", noteIds)
            .execute()
        : [];

    // Create a map of note_id to tags
    const tagsMap = new Map<string, any>();
    for (const tagRecord of tagsData) {
      if (tagRecord.note_id) {
        tagsMap.set(tagRecord.note_id, tagRecord.tags);
      }
    }

    // Check if ContactAccess.Read permission is granted to include author email
    const includeAuthorEmail =
      plot.plotOptions?.contact?.access !== undefined &&
      plot.plotOptions.contact.access >= ContactAccess.Read;

    return rows.map((row) => {
      const author = authorMap.get(row.author_id);
      if (!author) {
        throw new Error("Note author not found");
      }
      return {
        // @ts-ignore - row.id is a string from DB, but Uuid is a branded type
        id: row.id as any,
        created: row.source_created_at
          ? new Date(row.source_created_at)
          : new Date(row.created_at),
        thread: activity, // Use the thread parameter passed to the function
        author: {
          id: author.id as ActorId,
          type: author.type as unknown as ActorType,
          name: author.name ?? null,
          email: includeAuthorEmail ? author.email ?? undefined : undefined,
        },
        private: row.private,
        archived: row.archived_at !== null,
        content: row.content,
        key: row.key || null,
        reNote: row.re_note_id ? { id: row.re_note_id as Uuid } : null,
        actions: row.actions as Action[] | null,
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
