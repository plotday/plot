import LinkifyIt from "linkify-it";

import { type Database, DbError, type Json } from "@plotday/db";
import type {
  ActorId,
  ActorType,
  NewActivity,
  NewActivityOccurrence,
  NewActivityWithNotes,
  NewActor,
  PickPriorityConfig,
} from "@plotday/twister/plot";
import { ActivityType } from "@plotday/twister/plot";

import { createLogger } from "@plotday/worker-util";
import { addContacts } from "./contacts";
import { calculateDbEndFromRecurrenceUntil, formatInterval } from "./datetime";
import type { Plot } from "./index";

/**
 * Converts start/end dates to database range format, handling recurrence end calculation.
 * Returns {at?, on?, duration} where only the appropriate range field is set:
 * - If either input is a Date, returns {at: range} (timestamp range)
 * - If both are strings, returns {on: range} (date range)
 * - If start is falsy, returns empty range fields
 */
export function toDbRange(
  start: Date | string | null | undefined,
  end: Date | string | null | undefined,
  recurrenceUntil?: Date | string | null,
  recurrenceCount?: number,
  recurrenceRule?: string | null
): { at?: string | null; on?: string | null; duration?: number | null } {
  if (start === null) {
    return { at: null, on: null, duration: null };
  } else if (start === undefined) {
    return { at: undefined, on: undefined, duration: undefined };
  }

  // Calculate dbEnd and duration using existing helper
  const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
    start ?? null,
    end ?? null,
    recurrenceUntil ?? null,
    recurrenceCount,
    recurrenceRule ?? null
  );

  if (start instanceof Date || dbEnd instanceof Date) {
    // Timestamp range - use 'at' field
    const startStr =
      start instanceof Date ? start.toISOString() : `${start}T00:00:00Z`;
    const endStr =
      dbEnd instanceof Date
        ? dbEnd.toISOString()
        : dbEnd
        ? `${dbEnd}T23:59:59Z`
        : null;

    if (startStr && endStr) {
      return { at: `[${startStr},${endStr})`, on: null, duration };
    } else if (startStr) {
      return { at: `[${startStr},)`, on: null, duration };
    }
    return { duration };
  } else {
    // Date range - use 'on' field (both are strings)
    if (start && dbEnd) {
      return { on: `[${start},${dbEnd})`, at: null, duration };
    } else if (start) {
      return { on: `[${start},)`, at: null, duration };
    }
    return { duration };
  }
}

/** Type alias for activity insert operations */
type ActivityInsert = Database["public"]["Tables"]["activity"]["Insert"];
type ActivityUpdate = Database["public"]["Tables"]["activity"]["Update"];

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
export function createPreviewFromMarkdown(
  markdown: string | null | undefined
): string | null {
  if (!markdown) return null;

  let preview = markdown;

  // Strip markdown formatting
  // Remove code blocks
  preview = preview.replace(/```[\s\S]*?```/g, "");
  preview = preview.replace(/`[^`]+`/g, "");

  // Remove headers
  preview = preview.replace(/^#+\s+/gm, "");

  // Remove links but keep link text
  preview = preview.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");

  // Remove images
  preview = preview.replace(/!\[([^\]]*)\]\([^)]+\)/g, "");

  // Remove bold/italic
  preview = preview.replace(/(\*\*|__)(.*?)\1/g, "$2");
  preview = preview.replace(/(\*|_)(.*?)\1/g, "$2");

  // Remove strikethrough
  preview = preview.replace(/~~(.*?)~~/g, "$1");

  // Remove blockquotes
  preview = preview.replace(/^>\s+/gm, "");

  // Remove horizontal rules
  preview = preview.replace(/^[-*_]{3,}$/gm, "");

  // Remove list markers
  preview = preview.replace(/^[\s]*[-*+]\s+/gm, "");
  preview = preview.replace(/^[\s]*\d+\.\s+/gm, "");

  // Replace multiple newlines with single space
  preview = preview.replace(/\n+/g, " ");

  // Replace multiple spaces with single space
  preview = preview.replace(/\s+/g, " ");

  // Trim whitespace
  preview = preview.trim();

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
  const newContacts: Array<{ email: string; name?: string; avatar?: string }> =
    [];
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

  // Batch upsert all priority_contact links at once
  if (actorIds.length > 0) {
    const priorityContacts = actorIds.map((actorId) => ({
      priority_id: priorityId,
      contact_id: actorId,
    }));

    const { error } = await plot.supabase
      .from("priority_contact")
      .upsert(priorityContacts, {
        onConflict: "priority_id,contact_id",
      });

    if (error) {
      throw new Error(`Failed to link contacts to priority: ${error.message}`);
    }
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
 * Derives the default assignee for an activity based on type and explicit assignment.
 *
 * Logic:
 * - If assignee is explicitly provided (including null), returns the explicit value
 * - For actions without explicit assignee, calls get_priority_twist_owner_contact RPC
 * - For notes/events without explicit assignee, returns undefined (no assignee)
 *
 * @param plot - The Plot instance
 * @param activityType - The database activity type ('note' | 'action' | 'event')
 * @returns The assignee ID, null, or undefined (meaning "not provided")
 */
export async function getPriorityTwistOwnerContact(
  plot: Plot
): Promise<string | null | undefined> {
  const result = await plot.supabase.rpc("get_priority_twist_owner_contact", {
    p_priority_twist_id: plot.priorityTwistId,
  });
  // We should always have an owner contact
  return result.data ?? null;
}

/**
 * Result of preparing an activity for database insertion/upsert.
 */
export type PreparedActivity = (
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

  /** The original occurrences array (SDK format, for processOccurrences after insert/upsert) */
  occurrences: NewActivityOccurrence[];
};

/**
 * Prepares a NewActivity for database insertion, handling all common preparation logic:
 * - Priority resolution (including pickPriority embedding-based selection)
 * - Activity type mapping and action start default
 * - Scheduling validation
 * - Preview generation from notes
 * - Author and assignee processing
 * - Database object construction
 * - Scheduling field building
 * - Occurrence array formatting
 *
 * For non-source activities, this function derives the default assignee for actions.
 * For source-based activities, the assignee is only processed if explicit (the RPC derives default).
 *
 * @param plot - The Plot instance
 * @param activity - The NewActivity or NewActivityWithNotes to prepare
 * @returns PreparedActivity containing all data needed for insertion
 */
export async function prepareActivityForDb(
  plot: Plot,
  activity: NewActivity | NewActivityWithNotes
): Promise<PreparedActivity> {
  // Activity exceptions are handled via occurrences[] array
  if ("recurrence" in activity || "occurrence" in activity) {
    throw new Error(
      "Activity exceptions should use the occurrences[] array field, not recurrence/occurrence fields"
    );
  }

  await plot.validateActivityCreateAccess(activity);

  // Determine target priority, handling pickPriority for similarity-based selection
  let targetPriorityId: string;
  let embedding: number[] | null = null;

  // Determine pickPriority config: explicit priority, provided config, or default
  let pickPriorityConfig: PickPriorityConfig | undefined;
  if ("priority" in activity) {
    // Explicit priority provided, don't use pickPriority
    pickPriorityConfig = undefined;
  } else if ("pickPriority" in activity) {
    // pickPriority key exists, use it (or default to {content: true} if undefined)
    pickPriorityConfig = activity.pickPriority ?? { content: true };
  } else {
    // Neither priority nor pickPriority key exists, use default
    pickPriorityConfig = { content: true };
  }

  // Apply pickPriority logic if config is defined
  if (pickPriorityConfig) {
    // Parse config into required filters and scored fields
    const requiredFilters: Record<string, true> = {};
    const scoredFields: Record<string, number> = {};

    for (const [key, value] of Object.entries(pickPriorityConfig)) {
      if (value === true) {
        requiredFilters[key] = true;
      } else if (typeof value === "number") {
        scoredFields[key] = value;
      }
    }

    // Generate embedding if content is in config
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
          // embedding remains null, will use default priority logic
        }
      }
    }

    // Build activity data for comparison
    const activityData: any = {
      type: activity.type,
      meta: activity.meta || {},
    };

    // Call find_matching_activities_scored with configured filters and scoring
    const matchResult = await plot.supabase.rpc(
      "find_matching_activities_scored",
      {
        query_embedding: embedding ? JSON.stringify(embedding) : "[]",
        created_by_id: plot.priorityTwistId,
        required_filters: requiredFilters,
        scored_fields: scoredFields,
        activity_data: activityData,
        similarity_threshold: 0.7, // Strong match threshold for required content
      }
    );

    if (
      matchResult.data &&
      Array.isArray(matchResult.data) &&
      matchResult.data.length > 0
    ) {
      // Use the priority from the best matching activity
      targetPriorityId = matchResult.data[0].priority_id;
    } else {
      // No matching activities found, use default
      targetPriorityId = plot.priorityId;
    }
  } else {
    // Explicit priority specified or use default
    if ("priority" in activity) {
      // Validate that priority has a valid id when explicitly provided
      if (!activity.priority?.id) {
        throw new Error(
          "Invalid priority: when providing 'priority', it must have a valid 'id' field"
        );
      }
      targetPriorityId = activity.priority.id;
    } else {
      targetPriorityId = plot.priorityId;
    }
  }

  await plot.validatePriorityAccess(targetPriorityId);

  // Map ActivityType enum to database activity_type
  let dbActivityType: "note" | "action" | "event" = "note";
  if (activity.type !== undefined) {
    switch (activity.type) {
      case ActivityType.Note:
        dbActivityType = "note";
        break;
      case ActivityType.Action:
        dbActivityType = "action";
        if (activity.start === undefined) {
          activity.start = new Date();
        }
        break;
      case ActivityType.Event:
        dbActivityType = "event";
        break;
    }
  }

  // Extract occurrences array (SDK format) - will be processed after insert/upsert via processOccurrences
  const occurrences: NewActivityOccurrence[] =
    "occurrences" in activity && activity.occurrences
      ? activity.occurrences
      : [];

  // Validate scheduling requirements (database constraint: activity_scheduled)
  // Events MUST have scheduling, and activities with recurrence rules MUST have scheduling
  // For activities with occurrences, we can fall back to the first occurrence
  const hasSource = "source" in activity && activity.source;

  if (
    dbActivityType === "event" &&
    ((!activity.start && !occurrences[0]?.start) ||
      (!activity.end && !occurrences[0]?.end))
  ) {
    throw new Error("Events must have a start and end.");
  }
  if (activity.recurrenceRule && !activity.start && !occurrences[0]?.start) {
    throw new Error("Recurring activities must have a start.");
  }

  // Calculate scheduling for defaults (with occurrence fallbacks for start AND end)
  const defaultStart = activity.start ?? occurrences[0]?.start;
  const defaultEnd = activity.end ?? occurrences[0]?.end;
  const defaultRange = toDbRange(
    defaultStart,
    defaultEnd,
    activity.recurrenceUntil,
    activity.recurrenceCount ?? undefined,
    activity.recurrenceRule
  );

  // Generate preview from explicit preview field or fall back to notes
  let previewText: string | null = null;

  // Prefer explicit preview field
  if ("preview" in activity && activity.preview !== undefined) {
    if (activity.preview === null) {
      // Explicitly set to null - no preview
      previewText = null;
    } else {
      // Explicit preview provided - use it
      previewText = createPreviewFromMarkdown(activity.preview);
    }
  } else if (
    "notes" in activity &&
    activity.notes &&
    activity.notes.length > 0
  ) {
    // Legacy fallback: generate from first note with content
    const firstNoteWithContent = activity.notes.find((note) => note.content);
    if (firstNoteWithContent && firstNoteWithContent.content) {
      // Convert note to markdown first if needed
      const markdown = await convertNoteToMarkdown(
        plot.env.AI,
        firstNoteWithContent.content,
        firstNoteWithContent.contentType
      );
      previewText = createPreviewFromMarkdown(markdown);
    }
  }

  // Process author - use provided author or default to twist
  // When author is provided, processNewActor will always return a non-null ID
  // (it only returns null when passed null, which we don't do here)
  const authorId: string = activity.author
    ? (await processNewActor(plot, activity.author, targetPriorityId))!
    : plot.priorityTwistId;

  // Process assignee - behavior depends on whether activity has a source
  // For source activities: only process if explicit (let RPC derive default)
  // For non-source activities: derive default for actions via RPC call here
  let assigneeId: string | null | undefined = undefined;
  const assigneeWasExplicitlySet = activity.assignee !== undefined;
  if (assigneeWasExplicitlySet) {
    // Assignee is explicitly provided (can be NewActor or null)
    assigneeId = await processNewActor(
      plot,
      activity.assignee,
      targetPriorityId
    );
  } else if (!hasSource && dbActivityType === "action") {
    // Non-source activity without explicit assignee - derive default for actions
    assigneeId = await getPriorityTwistOwnerContact(plot);
  }
  // For source activities without explicit assignee, leave assigneeId undefined
  // so upsert_activity RPC can derive the default

  // Build defaults object - contains all calculated defaults for INSERT
  // This is used for plain inserts (no source) or as fallback values for upserts
  const defaults: ActivityInsert = {
    author_id: authorId,
    created_by: plot.priorityTwistId,
    updated_by: plot.getUpdatedBy(),
    priority_id: targetPriorityId,
    source_created_at:
      activity.created?.toISOString() ?? new Date().toISOString(),
    type: dbActivityType,
    // Always include title with 'Untitled' fallback for constraint satisfaction
    title: (activity.title ?? occurrences[0]?.title)?.trim() || "Untitled",
    preview: previewText,
    draft: false,
    private: activity.private ?? false,
    at: defaultRange.at ?? null,
    on: defaultRange.on ?? null,
    duration: defaultRange.duration
      ? formatInterval(defaultRange.duration)
      : null,
    done_at: activity.done ? activity.done.toISOString() : null,
    recurrence_rule: activity.recurrenceRule ?? null,
    recurrence_exdates:
      activity.recurrenceExdates?.map((d) => d.toISOString()) ?? [],
    meta: (activity.meta ?? null) as Json | null,
    sync_depth: plot.syncDepth + 1,
    embedding: embedding ? JSON.stringify(embedding) : null,
    pick_priority: (pickPriorityConfig ?? null) as Json | null,
    // Only include archived_at if explicitly set
    ...(activity.archived !== undefined
      ? { archived_at: activity.archived ? new Date().toISOString() : null }
      : {}),
    // Conditionally add optional fields
    ...("id" in activity && activity.id ? { id: activity.id } : {}),
    ...(assigneeId !== undefined ? { assignee_id: assigneeId } : {}),
  };

  // Return different structures based on whether activity has a source
  if (hasSource) {
    // Build upsert object - only contains explicitly provided values (no defaults)
    // Keys present in this object will be updated; absent keys preserve existing values
    const upsertFields: ActivityUpdate = {
      // Always include source for upsert conflict resolution
      source: activity.source,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      // Only include archived_at if explicitly set
      ...(activity.archived !== undefined
        ? { archived_at: activity.archived ? new Date().toISOString() : null }
        : {}),
    };

    // Add fields only if explicitly provided (not using defaults)
    if (activity.title !== undefined) {
      upsertFields.title =
        activity.title && activity.title.trim() !== "" ? activity.title : null;
    }
    // Include preview in update if explicitly provided (even if null, to clear it)
    if ("preview" in activity && activity.preview !== undefined) {
      upsertFields.preview = previewText;
    }
    if (activity.type !== undefined) {
      upsertFields.type = dbActivityType;
    }
    if (activity.private !== undefined) {
      upsertFields.private = activity.private;
    }
    if (activity.done !== undefined) {
      upsertFields.done_at = activity.done ? activity.done.toISOString() : null;
    }
    if (activity.recurrenceRule !== undefined) {
      upsertFields.recurrence_rule = activity.recurrenceRule;
    }
    if (activity.recurrenceExdates !== undefined) {
      upsertFields.recurrence_exdates =
        activity.recurrenceExdates?.map((d) => d.toISOString()) ?? [];
    }
    if (activity.meta !== undefined) {
      upsertFields.meta = activity.meta as Json | null;
    }
    if (assigneeId !== undefined) {
      upsertFields.assignee_id = assigneeId;
    }
    if (defaultRange.duration) {
      upsertFields.duration = formatInterval(defaultRange.duration);
    }

    // For upsert: only use activity.start/end (no occurrence fallbacks)
    const upsertRange = toDbRange(
      activity.start,
      activity.end,
      activity.recurrenceUntil,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule
    );
    if (upsertRange.at !== undefined) {
      upsertFields.at = upsertRange.at;
    }
    if (upsertRange.on !== undefined) {
      upsertFields.on = upsertRange.on;
    }

    // For actions with null assignee, force scheduling to null
    if (dbActivityType === "action" && assigneeId === null) {
      upsertFields.at = null;
      upsertFields.on = null;
    }
    return {
      upsert: upsertFields,
      defaults,
      priorityId: targetPriorityId,
      occurrences,
    };
  } else {
    return {
      insert: defaults,
      priorityId: targetPriorityId,
      occurrences,
    };
  }
}
