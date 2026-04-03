import LinkifyIt from "linkify-it";

import { type Database, DbError } from "@plotday/db";
import type {
  ActorId,
  ActorType,
  NewThread,
  NewThreadWithNotes,
  NewActor,
  NewContact,
} from "@plotday/twister/plot";

import { createLogger } from "@plotday/worker-util";
import { rpc } from "../../../rpc";
import { addContacts } from "./contacts";
import type { Plot } from "./index";

/** Type alias for thread insert operations (DB table is now "thread") */
type ActivityInsert = Database["public"]["Tables"]["thread"]["Insert"];
type ActivityUpdate = Database["public"]["Tables"]["thread"]["Update"];

/**
 * Handles errors from database operations:
 * - DbError (unexpected): Logs with full context and stack trace, then throws generic error
 * - Regular Error (expected): Re-throws unchanged for caller to handle
 */
export function handleDbOperationError(
  error: unknown,
  operation: string,
  priorityTwistId: string,
  context: Record<string, unknown>
): never {
  if (error instanceof DbError) {
    // Log full error with stack trace for debugging (PostHog/console)
    const logger = createLogger({ priority_twist_id: priorityTwistId });

    // Extract PostgrestError from cause for full debugging info
    const cause = error.cause as
      | { code?: string; hint?: string; details?: string }
      | undefined;

    logger.error(`Unexpected database error in ${operation}`, error as Error, {
      operation,
      ...context,
      // Include PostgreSQL-specific error details
      db_code: cause?.code,
      db_hint: cause?.hint,
      db_details: cause?.details,
    });
    // Sanitize: throw generic error to caller
    throw new Error("Something went wrong");
  }
  // Expected errors (validation, not found, etc.) pass through unchanged
  throw error;
}

/**
 * Converts ActorType enum to database actor type string.
 */
export function actorTypeToString(type: ActorType): string {
  switch (type) {
    case 0: // ActorType.User
      return "user";
    case 1: // ActorType.Contact
      return "contact";
    case 2: // ActorType.Twist
      return "priority_twist";
    default:
      return "user";
  }
}

/**
 * Converts note content to Markdown based on the specified contentType.
 *
 * @param ai - The Cloudflare Workers AI binding
 * @param note - The note content to convert
 * @param contentType - The format of the input note ('text', 'markdown', 'html', or null)
 * @returns The note content converted to Markdown
 */
export async function convertNoteToMarkdown(
  ai: Ai,
  note: string | null | undefined,
  contentType?: "text" | "markdown" | "html"
): Promise<string | null> {
  if (!note) return null;

  // Default to 'markdown' if contentType is not specified
  const type = contentType ?? "markdown";

  switch (type) {
    case "html": {
      // Convert HTML to Markdown using Cloudflare Workers AI
      try {
        const result = await ai.toMarkdown({
          name: "note.html",
          blob: new Blob([note], { type: "text/html" }),
        });

        // Check if conversion was successful
        if (result.format === "markdown") {
          return result.data;
        }

        // Handle error case (format === "error")
        if ("error" in result) {
          const logger = createLogger();
          logger.error(
            "Failed to convert HTML to Markdown",
            new Error(String(result.error))
          );
          return note;
        }

        // Fallback for unexpected format
        const logger = createLogger();
        logger.error("Unexpected toMarkdown response format", { result });
        return note;
      } catch (error) {
        // If conversion fails, return original note
        const logger = createLogger();
        logger.error("Failed to convert HTML to Markdown", error as Error);
        return note;
      }
    }

    case "text": {
      // Decode HTML entities
      let converted = note
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'")
        .replace(/&nbsp;/g, " ");

      // Auto-link URLs using linkify-it for robust URL detection
      const linkify = new LinkifyIt();
      const matches = linkify.match(converted);

      if (matches) {
        // Process matches in reverse order to preserve string positions
        for (let i = matches.length - 1; i >= 0; i--) {
          const match = matches[i];
          const markdownLink = `[${match.raw}](${match.url})`;
          converted =
            converted.substring(0, match.index) +
            markdownLink +
            converted.substring(match.lastIndex);
        }
      }

      // Preserve line breaks by converting single newlines to double newlines
      // This ensures text line breaks are preserved in Markdown rendering
      converted = converted.replace(/\n/g, "\n\n");

      return converted;
    }

    case "markdown":
    default:
      // Already in Markdown format, return as-is
      return note;
  }
}

/**
 * Creates a preview string from markdown content.
 * Strips markdown formatting, newlines, and truncates to 100 characters.
 *
 * @param markdown - The markdown content to create a preview from
 * @returns A plain text preview (max 100 characters) or null if input is empty
 */

/** Strips markdown formatting from text, keeping plain text content. */
export function stripMarkdown(text: string): string {
  let result = text;

  // Strip HTML tags (keep inner text)
  result = result.replace(/<[^>]+>/g, "");

  // Decode common HTML entities
  result = result
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");

  // Remove code blocks
  result = result.replace(/```[\s\S]*?```/g, "");
  result = result.replace(/`[^`]+`/g, "");

  // Remove headers
  result = result.replace(/^#+\s+/gm, "");

  // Remove images (before links so ![alt](url) doesn't become [alt](url))
  result = result.replace(/!\[([^\]]*)\]\([^)]+\)/g, "");

  // Remove links but keep link text
  result = result.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");

  // Remove bold/italic
  result = result.replace(/(\*\*|__)(.*?)\1/g, "$2");
  result = result.replace(/(\*|_)(.*?)\1/g, "$2");

  // Remove strikethrough
  result = result.replace(/~~(.*?)~~/g, "$1");

  // Remove blockquotes
  result = result.replace(/^>\s+/gm, "");

  // Remove horizontal rules
  result = result.replace(/^[-*_]{3,}$/gm, "");

  // Remove list markers
  result = result.replace(/^[\s]*[-*+]\s+/gm, "");
  result = result.replace(/^[\s]*\d+\.\s+/gm, "");

  return result;
}

/**
 * Strips markdown formatting from a title.
 * "Complete [GTM Module 4 assignments](https://example.com)" → "Complete GTM Module 4 assignments"
 */
export function cleanTitle(title: string): string {
  return stripMarkdown(title).replace(/\s+/g, " ").trim();
}

export function createPreviewFromMarkdown(
  markdown: string | null | undefined
): string | null {
  if (!markdown) return null;

  let preview = stripMarkdown(markdown);

  // Strip raw URLs (standalone URLs not part of markdown links)
  preview = preview.replace(/https?:\/\/[^\s)>\]]+/g, "");

  // Replace newlines with " / " separator
  preview = preview.replace(/\n+/g, " / ");

  // Replace multiple spaces with single space
  preview = preview.replace(/\s+/g, " ");

  // Clean up separator artifacts (e.g. "/ /" or leading/trailing " / ")
  preview = preview.replace(/(\s*\/\s*)+/g, " / ");

  // Trim whitespace and separators
  preview = preview.replace(/^[\s/]+|[\s/]+$/g, "");

  // Truncate to 100 characters
  if (preview.length > 100) {
    preview = preview.substring(0, 100).trim() + "…";
  }

  return preview || null;
}

/**
 * Processes a NewActor (either an existing actor ID or a new contact) and returns the actor ID.
 * If the NewActor is a NewContact, it will be upserted and linked to the priority.
 *
 * @param plot - The Plot instance
 * @param newActor - The NewActor to process (can be { id } or NewContact)
 * @param priorityId - The priority ID to link new contacts to
 * @returns The actor ID, or null if newActor is undefined/null
 */
export async function processNewActor(
  plot: Plot,
  newActor: NewActor | undefined | null,
  priorityId: string
): Promise<string | null> {
  if (!newActor) return null;

  // Use batched version for single actor
  const result = await processNewActorArray(plot, [newActor], priorityId);
  return result.length > 0 ? result[0] : null;
}

/**
 * Processes an array of NewActors and returns an array of actor IDs.
 * Batches all database operations for efficiency.
 * Filters out any null/undefined results.
 *
 * @param plot - The Plot instance
 * @param newActors - Array of NewActors to process
 * @param priorityId - The priority ID to link new contacts to
 * @returns Array of actor IDs (nulls filtered out)
 */
export async function processNewActorArray(
  plot: Plot,
  newActors: NewActor[],
  priorityId: string
): Promise<ActorId[]> {
  if (newActors.length === 0) return [];

  // Separate existing actor IDs from new contacts
  const existingActorIds: ActorId[] = [];
  const newContacts: NewContact[] = [];
  const actorOrder: Array<{ type: "existing" | "new"; index: number }> = [];

  for (const newActor of newActors) {
    if (!newActor) continue;

    if ("id" in newActor) {
      // Existing actor reference
      actorOrder.push({ type: "existing", index: existingActorIds.length });
      existingActorIds.push(newActor.id as ActorId);
    } else {
      // New contact by email
      actorOrder.push({ type: "new", index: newContacts.length });
      newContacts.push(newActor);
    }
  }

  // Batch upsert all new contacts at once
  let createdActors: { id: ActorId }[] = [];
  if (newContacts.length > 0) {
    const actors = await addContacts(plot, newContacts);
    createdActors = actors.map((a) => ({ id: a.id }));
  }

  // Build the final actor IDs array in original order
  const actorIds: ActorId[] = actorOrder.map((order) => {
    if (order.type === "existing") {
      return existingActorIds[order.index];
    } else {
      return createdActors[order.index].id;
    }
  });

  // Batch upsert priority_contact links for contacts only (not priority_twists)
  // New contacts from addContacts are always valid, but existing actor IDs
  // may reference priority_twists which aren't in the contact table.
  const newContactIds = new Set(createdActors.map((a) => a.id));
  let contactIds = actorIds.filter((id) => newContactIds.has(id));

  // For existing actor IDs, check which ones are actually contacts
  const existingIdsToCheck = actorIds.filter((id) => !newContactIds.has(id));
  if (existingIdsToCheck.length > 0) {
    const validContacts = await plot.db
      .selectFrom("contact")
      .select("id")
      .where("id", "in", existingIdsToCheck)
      .execute();
    const validIds = new Set(validContacts.map((c) => c.id));
    contactIds = contactIds.concat(
      existingIdsToCheck.filter((id) => validIds.has(id))
    );
  }

  if (contactIds.length > 0) {
    const priorityContacts = contactIds.map((actorId) => ({
      priority_id: priorityId,
      contact_id: actorId,
    }));

    await plot.db
      .insertInto("priority_contact")
      .values(priorityContacts)
      .onConflict((oc) =>
        oc.columns(["priority_id", "contact_id"]).doNothing()
      )
      .execute();
  }

  return actorIds;
}

/**
 * Processes all tags for an activity, batching all actor operations across all tags.
 * This is more efficient than calling processNewActorArray per tag.
 *
 * @param plot - The Plot instance
 * @param tags - Record of tag IDs to NewActor arrays
 * @param priorityId - The priority ID to link new contacts to
 * @returns Record of tag IDs to ActorId arrays
 */
export async function processTagsActors(
  plot: Plot,
  tags: Partial<Record<number, NewActor[]>>,
  priorityId: string
): Promise<Partial<Record<number, ActorId[]>>> {
  // Collect all actors from all tags
  const allNewActors: NewActor[] = [];
  const tagActorMapping: Array<{
    tagId: number;
    startIdx: number;
    count: number;
  }> = [];

  for (const [tagIdStr, newActors] of Object.entries(tags)) {
    if (newActors && newActors.length > 0) {
      tagActorMapping.push({
        tagId: parseInt(tagIdStr),
        startIdx: allNewActors.length,
        count: newActors.length,
      });
      allNewActors.push(...newActors);
    }
  }

  if (allNewActors.length === 0) return {};

  // Process all actors in one batch
  const allActorIds = await processNewActorArray(
    plot,
    allNewActors,
    priorityId
  );

  // Map back to tag structure
  const result: Partial<Record<number, ActorId[]>> = {};
  for (const mapping of tagActorMapping) {
    const tagActorIds = allActorIds.slice(
      mapping.startIdx,
      mapping.startIdx + mapping.count
    );
    if (tagActorIds.length > 0) {
      result[mapping.tagId] = tagActorIds;
    }
  }

  return result;
}

/**
 * Result of preparing an activity for database insertion/upsert.
 */
export type PreparedThread = (
  | {
      /** Row to insert */
      insert: ActivityInsert;
    }
  | {
      /** Row to upsert */
      upsert: ActivityUpdate;
      /** Defaults to merge with upsert for the insert portion of the upsert */
      defaults: ActivityInsert;
    }
) & {
  priorityId: string;

  /** The resolved author contact ID (or priorityTwistId if no author specified) */
  authorId: string;
};

/**
 * Marks an activity as "read" for a note/activity author, if the author's
 * contact is linked to a user.
 *
 * Before upserting activity_read, checks whether there are unread notes from
 * other authors (using author_id). If so, the activity stays unread so the
 * user sees there is new content from others.
 *
 * Early returns (no-op) when:
 * - authorId is the priorityTwistId (no real author, just the twist default)
 * - author contact has no linked user_id
 * - there are unread notes from other authors since the user's last read_at
 *
 * @param plot - The Plot instance
 * @param authorId - The resolved author contact ID
 * @param activityId - The activity to mark as read
 * @param timestamp - The read_at timestamp to use
 */
export async function markThreadReadForAuthor(
  plot: Plot,
  authorId: string,
  activityId: string,
  timestamp: string
): Promise<void> {
  // No real author — just the twist itself
  if (authorId === plot.priorityTwistId) {
    return;
  }

  try {
    // Look up whether this contact is linked to a user
    const contact = await plot.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", authorId)
      .executeTakeFirst();

    const userId = contact?.user_id;
    if (!userId) {
      return;
    }

    // Check if there are unread notes from other authors since this user's
    // last read_at — mirrors the DB trigger logic but uses author_id (the real
    // author) instead of created_by (which is the twist for synced notes).
    const existingRead = await plot.db
      .selectFrom("thread_read")
      .select("read_at")
      .where("user_id", "=", userId)
      .where("thread_id", "=", activityId)
      .executeTakeFirst();

    const lastReadAt = existingRead?.read_at ?? null;

    let unreadFromOthersQuery = plot.db
      .selectFrom("note")
      .select("id")
      .where("thread_id", "=", activityId)
      .where("draft", "=", false)
      .where("archived_at", "is", null)
      .where((eb) =>
        eb.or([
          eb("author_id", "is", null),
          eb("author_id", "!=", authorId),
        ])
      )
      .limit(1);

    if (lastReadAt) {
      const readAtDate =
        lastReadAt instanceof Date
          ? lastReadAt
          : new Date(lastReadAt);
      unreadFromOthersQuery = unreadFromOthersQuery.where(
        "source_created_at",
        ">",
        readAtDate
      );
    }

    const unreadFromOthers = await unreadFromOthersQuery.executeTakeFirst();

    if (unreadFromOthers) {
      // There are unread notes from other authors — keep activity unread
      return;
    }

    // Upsert a single activity_read entry for the author
    try {
      await plot.db
        .insertInto("thread_read")
        .values({
          thread_id: activityId,
          user_id: userId,
          read_at: timestamp,
        })
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
        "Failed to auto-mark activity as read for author",
        upsertError as Error,
        { thread_id: activityId, user_id: userId }
      );
    }
  } catch (error) {
    // Log but don't throw — read status is non-critical
    const logger = createLogger({
      priority_twist_id: plot.priorityTwistId,
    });
    logger.error(
      "Error in markThreadReadForAuthor",
      error as Error,
      { thread_id: activityId, author_id: authorId }
    );
  }
}

/**
 * Prepares a NewThread for database insertion, handling all common preparation logic:
 * - Priority resolution (including pickPriority embedding-based selection)
 * - Activity type mapping
 * - Preview generation from notes
 * - Author and assignee processing
 * - Database object construction
 *
 * For non-source activities, this function derives the default assignee for actions.
 * For source-based activities, the assignee is only processed if explicit (the RPC derives default).
 *
 * @param plot - The Plot instance
 * @param activity - The NewThread or NewThreadWithNotes to prepare
 * @returns PreparedThread containing all data needed for insertion
 */
export async function prepareThreadForDb(
  plot: Plot,
  activity: NewThread | NewThreadWithNotes
): Promise<PreparedThread> {
  // Activity exceptions are handled via occurrences[] array
  if ("recurrence" in activity || "occurrence" in activity) {
    throw new Error(
      "Activity exceptions should use the occurrences[] array field, not recurrence/occurrence fields"
    );
  }

  await plot.validateActivityCreateAccess(activity);

  // Determine target priority
  let targetPriorityId: string;

  if ("priority" in activity) {
    if (!activity.priority?.id) {
      throw new Error(
        "Invalid priority: when providing 'priority', it must have a valid 'id' field"
      );
    }
    targetPriorityId = activity.priority.id;
  } else if ("pickPriority" in activity) {
    // pickPriority-based selection — uses embedding similarity
    const pickPriorityConfig = activity.pickPriority ?? { content: true };
    const requiredFilters: Record<string, true> = {};
    const scoredFields: Record<string, number> = {};

    for (const [key, value] of Object.entries(pickPriorityConfig)) {
      if (value === true) {
        requiredFilters[key] = true;
      } else if (typeof value === "number") {
        scoredFields[key] = value;
      }
    }

    let embedding: number[] | null = null;
    if (pickPriorityConfig.content !== undefined) {
      const firstNote =
        "notes" in activity && activity.notes?.[0]?.content
          ? activity.notes[0].content
          : null;
      const textToEmbed = [activity.title, firstNote]
        .filter(Boolean)
        .join("\n");

      if (textToEmbed.trim().length > 0) {
        try {
          embedding = await plot.ai.embed(textToEmbed);
        } catch (error) {
          const logger = createLogger({
            priority_twist_id: plot.priorityTwistId,
          });
          logger.warn(
            "Failed to generate embedding for pickPriority, falling back to default priority",
            {
              error_message:
                error instanceof Error ? error.message : String(error),
            }
          );
        }
      }
    }

    if (!embedding && (requiredFilters.content || scoredFields.content)) {
      targetPriorityId = plot.priorityId;
    } else {
      const matchResult = await rpc(plot.db, "find_matching_threads_scored", {
        query_embedding: embedding ? JSON.stringify(embedding) : "[]",
        created_by_id: plot.priorityTwistId,
        required_filters: requiredFilters,
        scored_fields: scoredFields,
        thread_data: {},
        similarity_threshold: 0.7,
      });

      const matchArray = Array.isArray(matchResult)
        ? matchResult
        : matchResult
          ? [matchResult]
          : [];
      if (matchArray.length > 0) {
        targetPriorityId = (matchArray[0] as any).priority_id;
      } else {
        targetPriorityId = plot.priorityId;
      }
    }
  } else {
    targetPriorityId = plot.priorityId;
  }

  await plot.validatePriorityAccess(targetPriorityId);

  // Generate preview from explicit preview field or fall back to notes
  let previewText: string | null = null;

  if ("preview" in activity && activity.preview !== undefined) {
    if (activity.preview === null) {
      previewText = null;
    } else {
      previewText = createPreviewFromMarkdown(activity.preview);
    }
  } else if (
    "notes" in activity &&
    activity.notes &&
    activity.notes.length > 0
  ) {
    const firstNoteWithContent = activity.notes.find((note) => note.content);
    if (firstNoteWithContent && firstNoteWithContent.content) {
      const markdown = await convertNoteToMarkdown(
        plot.env.AI,
        firstNoteWithContent.content,
        firstNoteWithContent.contentType
      );
      previewText = createPreviewFromMarkdown(markdown);
    }
  }

  // Resolve thread-level author for read-marking.
  // The author field comes from NewLink.author (passed via createLink → createThread).
  // created_by in the DB remains plot.priorityTwistId (the twist created it).
  let authorId = plot.priorityTwistId;
  if ("author" in activity && (activity as any).author) {
    const resolvedAuthorId = await processNewActor(
      plot,
      (activity as any).author,
      targetPriorityId
    );
    if (resolvedAuthorId) {
      authorId = resolvedAuthorId as ActorId;
    }
  }

  // Build defaults object for INSERT
  const defaults: ActivityInsert = {
    created_by: plot.priorityTwistId,
    updated_by: plot.getUpdatedBy(),
    priority_id: targetPriorityId,
    title: cleanTitle(activity.title?.trim() || "Untitled"),
    preview: previewText,
    draft: false,
    private: activity.private ?? false,
    sync_depth: plot.syncDepth + 1,
    ...(activity.archived !== undefined
      ? { archived_at: activity.archived ? new Date().toISOString() : null }
      : {}),
    ...("id" in activity && activity.id ? { id: activity.id } : {}),
    ...("key" in activity && (activity as any).key !== undefined
      ? { key: (activity as any).key }
      : {}),
    // Map SDK 'type' field to database 'icon' column, with 'icon' as fallback for internal callers
    ...("type" in activity && (activity as any).type !== undefined
      ? { icon: (activity as any).type }
      : "icon" in activity && (activity as any).icon !== undefined
        ? { icon: (activity as any).icon }
        : {}),
  };

  // Source-based threads use upsert, non-source use insert
  const hasSource = "source" in activity && activity.source;

  if (hasSource) {
    const upsertFields: ActivityUpdate = {
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      ...(activity.archived !== undefined
        ? { archived_at: activity.archived ? new Date().toISOString() : null }
        : {}),
      // key must be in upsert (p_thread) so upsert_thread can look up
      // existing threads by (key, priority_id) for database-level dedup
      ...("key" in activity && (activity as any).key !== undefined
        ? { key: (activity as any).key }
        : {}),
    };

    if (activity.title !== undefined) {
      // Only include title in upsert if it's non-empty.
      // Cancelled/deleted events (e.g. Google Calendar) send title: null,
      // which would violate thread_title_required_when_not_draft constraint.
      if (activity.title && activity.title.trim() !== "") {
        upsertFields.title = cleanTitle(activity.title);
      }
    }
    if ("preview" in activity && activity.preview !== undefined) {
      upsertFields.preview = previewText;
    }
    if (activity.private !== undefined) {
      upsertFields.private = activity.private;
    }
    if ("type" in activity && (activity as any).type !== undefined) {
      upsertFields.icon = (activity as any).type;
    } else if ("icon" in activity && (activity as any).icon !== undefined) {
      upsertFields.icon = (activity as any).icon;
    }

    return {
      upsert: upsertFields,
      defaults,
      priorityId: targetPriorityId,
      authorId,
    };
  } else {
    return {
      insert: defaults,
      priorityId: targetPriorityId,
      authorId,
    };
  }
}

/** @deprecated Use markThreadReadForAuthor */
export const markActivityReadForAuthor = markThreadReadForAuthor;
/** @deprecated Use prepareThreadForDb */
export const prepareActivityForDb = prepareThreadForDb;
/** @deprecated Use PreparedThread */
export type PreparedActivity = PreparedThread;
