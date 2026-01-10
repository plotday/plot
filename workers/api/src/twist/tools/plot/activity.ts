import LinkifyIt from "linkify-it";

import { type Database, safeQuery } from "@plotday/db";
import {
  type Activity,
  type ActivityLink,
  type ActivityMeta,
  ActivityType,
  type ActivityUpdate,
  type ActorId,
  ActorType,
  type NewActivity,
  type NewActivityWithNotes,
  type NewActor,
  type NewNote,
  type Note,
  type NoteUpdate,
  type PickPriorityConfig,
  type Tag,
  type Uuid,
} from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";

import { createLogger } from "../../../utils/logger";
import { addContacts } from "./contacts";
import { fromDbActivity } from "./converters";
import { calculateDbEndFromRecurrenceUntil, formatInterval } from "./datetime";
import type { Plot } from "./index";

/**
 * Converts ActorType enum to database actor type string.
 */
function actorTypeToString(type: ActorType): string {
  switch (type) {
    case ActorType.User:
      return "user";
    case ActorType.Contact:
      return "contact";
    case ActorType.Twist:
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
async function convertNoteToMarkdown(
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
function createPreviewFromMarkdown(
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
async function processNewActor(
  plot: Plot,
  newActor: NewActor | undefined | null,
  priorityId: string
): Promise<string | null> {
  if (!newActor) return null;

  let actorId: string;

  if ("id" in newActor) {
    // Existing actor reference - use the ID directly
    actorId = newActor.id;
  } else {
    // New contact by email - upsert it
    const [actor] = await addContacts(plot, [newActor]);
    actorId = actor.id;
  }

  // Always link to priority (idempotent upsert)
  // This works for both existing and new actors
  const { error } = await plot.supabase.from("priority_contact").upsert(
    {
      priority_id: priorityId,
      contact_id: actorId,
      archived_at: null,
    },
    {
      onConflict: "priority_id,contact_id",
    }
  );

  if (error) {
    throw new Error(`Failed to link contact to priority: ${error.message}`);
  }

  return actorId;
}

/**
 * Processes an array of NewActors and returns an array of actor IDs.
 * Filters out any null/undefined results.
 *
 * @param plot - The Plot instance
 * @param newActors - Array of NewActors to process
 * @param priorityId - The priority ID to link new contacts to
 * @returns Array of actor IDs (nulls filtered out)
 */
async function processNewActorArray(
  plot: Plot,
  newActors: NewActor[],
  priorityId: string
): Promise<ActorId[]> {
  const actorIds: ActorId[] = [];

  for (const newActor of newActors) {
    const actorId = await processNewActor(plot, newActor, priorityId);
    if (actorId) {
      actorIds.push(actorId as ActorId);
    }
  }

  return actorIds;
}

export async function createActivity(
  plot: Plot,
  activity: NewActivity | NewActivityWithNotes
): Promise<Activity> {
  console.log('[createActivity] DEBUG activity.created:', activity.created, 'type:', typeof activity.created);
  if ('notes' in activity && activity.notes) {
    console.log('[createActivity] DEBUG first note created:', activity.notes[0]?.created, 'type:', typeof activity.notes[0]?.created);
  }

  // Handle activity exceptions differently
  if (activity.recurrence && activity.occurrence) {
    return createActivityException(plot, activity);
  }

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
    targetPriorityId =
      ("priority" in activity ? activity.priority.id : undefined) ??
      plot.priorityId;
  }

  await plot.validatePriorityAccess(targetPriorityId);

  // Validate activity create access permissions
  await plot.validateActivityCreateAccess(activity);

  // Map ActivityType enum to database activity_type
  let dbActivityType: "note" | "action" | "event" = "note";
  if (activity.type !== undefined) {
    switch (activity.type) {
      case ActivityType.Note:
        dbActivityType = "note";
        break;
      case ActivityType.Action:
        dbActivityType = "action";
        activity.start ??= new Date();
        break;
      case ActivityType.Event:
        dbActivityType = "event";
        break;
    }
  }

  // Calculate database end and duration from SDK format
  const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
    activity.start ?? null,
    activity.end ?? null,
    activity.recurrenceUntil ?? null,
    activity.recurrenceCount ?? undefined,
    activity.recurrenceRule ?? null
  );

  // Generate preview from first note with content
  let previewText: string | null = null;
  if ("notes" in activity && activity.notes && activity.notes.length > 0) {
    // Find first note with content
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
  const authorId = activity.author
    ? await processNewActor(plot, activity.author, targetPriorityId)
    : plot.priorityTwistId;

  // Process assignee
  let assigneeId: string | null = null;
  if (activity.assignee !== undefined) {
    // assignee is explicitly provided (can be NewActor or null)
    assigneeId = await processNewActor(
      plot,
      activity.assignee,
      targetPriorityId
    );
  } else if (dbActivityType === "action") {
    // For actions without explicit assignee, default to twist owner's contact
    // Use single query with join via database function
    const result = await plot.supabase.rpc(
      "get_priority_twist_owner_contact",
      {
        p_priority_twist_id: plot.priorityTwistId,
      }
    );

    if (result.error) {
      throw new Error(`Failed to get twist owner contact: ${result.error.message}`);
    }

    if (result.data) {
      assigneeId = result.data;
    }
  }

  // Get twist definition ID for upsert support
  const twistId = await plot.getTwistId(plot.priorityTwistId);

  // Convert NewActivity to database format
  // Note: created_by_twist_id is added by migration, not yet in generated types
  const dbActivity: any = {
    author_id: authorId,
    created_by: plot.priorityTwistId,
    created_by_twist_id: twistId,
    assignee_id: assigneeId,
    priority_id: targetPriorityId,
    source_created_at:
      activity.created?.toISOString() ?? new Date().toISOString(),
    type: dbActivityType,
    title:
      activity.title && activity.title.trim() !== "" ? activity.title : null,
    preview: previewText,
    draft: activity.draft ?? false,
    private: activity.private ?? false,
    duration: duration ? formatInterval(duration) : null,
    done_at: activity.done ? activity.done.toISOString() : null,
    recurrence_rule: activity.recurrenceRule ?? null,
    recurrence_exdates:
      activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null,
    recurrence_dates:
      activity.recurrenceDates?.map((d) => d.toISOString()) ?? null,
    meta: activity.meta ?? null,
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
    embedding: embedding ? JSON.stringify(embedding) : null,
    pick_priority: pickPriorityConfig ?? null,
  };

  // If tool provided an ID, use it instead of letting database generate one
  if ("id" in activity && activity.id) {
    dbActivity.id = activity.id;
  }

  // If tool provided a source, add it for upsert behavior
  if ("source" in activity && activity.source) {
    dbActivity.source = activity.source;
  }

  // Handle scheduling fields using calculated dbEnd
  if (
    (activity.start !== undefined && activity.start !== null) ||
    (dbEnd !== undefined && dbEnd !== null)
  ) {
    if (activity.start instanceof Date || dbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        dbEnd instanceof Date
          ? dbEnd.toISOString()
          : dbEnd
          ? `${dbEnd}T23:59:59Z`
          : null;

      if (startStr && endStr) {
        dbActivity.at = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbActivity.at = `[${startStr},)`;
      } else if (endStr) {
        // Start from beginning of time, end at specified time
        dbActivity.at = `(,${endStr}]`;
      }
    } else {
      // Date range
      const startStr = activity.start;
      const endStr = dbEnd;

      if (startStr && endStr) {
        dbActivity.on = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbActivity.on = `[${startStr},)`;
      } else if (endStr) {
        // Start from beginning of time, end at specified date
        dbActivity.on = `(,${endStr}]`;
      }
    }
  }

  // For actions with null assignee, force at and on to null (constraint requirement)
  if (dbActivityType === "action" && assigneeId === null) {
    const hadScheduling = dbActivity.at !== undefined || dbActivity.on !== undefined;
    dbActivity.at = null;
    dbActivity.on = null;
    if (hadScheduling) {
      console.warn(
        "[createActivity] Action with null assignee had scheduling fields - nullifying at/on to satisfy constraint"
      );
    }
  }

  // Insert or upsert activity based on whether source is provided
  // When source is provided, use upsert to handle duplicate sources within same priority root
  const dbResult = safeQuery(
    dbActivity.source
      ? await plot.supabase
          .from("activity")
          .upsert(dbActivity, { onConflict: "source,source_priority_root" })
          .select()
          .single()
      : await plot.supabase
          .from("activity")
          .insert(dbActivity)
          .select()
          .single()
  );

  // Process tags if provided - convert NewActor[] to ActorId[] for each tag
  let processedTags: Partial<Record<number, ActorId[]>> | null = null;
  if (activity.tags) {
    processedTags = {};
    for (const [tagId, newActors] of Object.entries(activity.tags)) {
      if (newActors && newActors.length > 0) {
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          targetPriorityId
        );
        if (actorIds.length > 0) {
          processedTags[parseInt(tagId)] = actorIds;
        }
      }
    }
  }

  // Add tags if provided
  if (processedTags) {
    // Build tag records with proper actor IDs from the processed tags object
    const newTags = Object.entries(processedTags)
      .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
      .flatMap(([tagId, actorIds]) =>
        actorIds!.map((actorId) => ({
          activity_id: dbResult.id,
          tag_id: parseInt(tagId),
          actor_id: actorId,
          updated_by: plot.getUpdatedBy(),
          sync_depth: plot.syncDepth + 1,
        }))
      );

    if (newTags.length > 0) {
      const { error: insertError } = await plot.supabase
        .from("activity_tag")
        .insert(newTags);

      if (insertError) {
        throw new Error(`Failed to insert tags: ${insertError.message}`);
      }
    }
  }

  // Create initial notes if provided
  if ("notes" in activity && activity.notes && activity.notes.length > 0) {
    // @ts-ignore - dbResult.id is a string from DB, but Uuid is a branded type
    await createNotes(
      plot,
      activity.notes.map((note) => ({
        ...note,
        activity: { id: dbResult.id as any },
      }))
    );
  }

  // Mark as read for all priority users if unread is false
  // This happens AFTER notes are created to ensure read_at timestamp is later than note timestamps
  if (activity?.unread === false) {
    // Get all users with access to this priority (including inherited access from parent priorities)
    const usersResult = await plot.supabase.rpc(
      "get_users_with_priority_access",
      {
        target_priority_id: targetPriorityId,
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
      const activityReadEntries = usersResult.data.map((pu) => ({
        activity_id: dbResult.id,
        user_id: pu.user_id,
        read_at: latestTimestamp,
      }));

      const insertResult = await plot.supabase
        .from("activity_read")
        .upsert(activityReadEntries, { onConflict: "user_id,activity_id" });
      if (insertResult.error) {
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

  // Get author from cached twist actor
  const author = await plot.getActor();

  // Check if ContactAccess.Read permission is granted to include author email
  const includeAuthorEmail =
    plot.plotOptions?.contact?.access !== undefined &&
    plot.plotOptions.contact.access >= ContactAccess.Read;

  return fromDbActivity(
    {
      ...dbResult,
      tags: processedTags || null,
      author: {
        id: author.id,
        name: author.name ?? "",
        type: actorTypeToString(author.type),
        email: author.email ?? null,
      },
      assignee: null,
    },
    includeAuthorEmail
  );
}

export async function createNote(
  plot: Plot,
  note: NewNote,
  skipActivityRead = false
): Promise<Note> {
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
    // Look up activity by source
    const { data: existingActivity, error: fetchError } = await plot.supabase
      .from("activity")
      .select("id")
      .eq("source", note.activity.source)
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

  await plot.validatePriorityAccess(activityData.priority_id);

  // Store activity data with non-null author for type safety
  const activityWithAuthor = {
    ...activityData,
    author: activityData.author,
    assignee: activityData.assignee ?? null,
  };

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
  const dbNote: any = {
    author_id: authorId,
    created_by: plot.priorityTwistId,
    activity_id: activityId,
    source_created_at: note.created?.toISOString() ?? new Date().toISOString(),
    draft: note.draft ?? false,
    private: note.private ?? false,
    content: contentToStore,
    links: note.links ?? null,
    mentions: mentionIds,
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
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
      const activityReadEntries = usersResult.data.map((pu) => ({
        activity_id: activityId,
        user_id: pu.user_id,
        read_at: dbResult.created_at, // Use note's created_at timestamp
      }));

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
      await plot.supabase.from("note_tag").insert(tagInserts);
    }
  }

  // Get author from cached twist actor
  const author = await plot.getActor();

  // Check if ContactAccess.Read permission is granted
  const includeAuthorEmail =
    plot.plotOptions?.contact?.access !== undefined &&
    plot.plotOptions.contact.access >= ContactAccess.Read;

  // Convert to Note type using cached activity data
  return {
    // @ts-ignore - dbResult.id is a string from DB, but Uuid is a branded type
    id: dbResult.id as any,
    created: (dbResult as any).source_created_at
      ? new Date((dbResult as any).source_created_at)
      : new Date(dbResult.created_at),
    activity: fromDbActivity(
      { ...activityWithAuthor, tags: null },
      includeAuthorEmail
    ),
    author: {
      id: author.id,
      type: author.type,
      name: author.name ?? null,
      email: includeAuthorEmail ? author.email ?? undefined : undefined,
    },
    draft: dbResult.draft,
    private: dbResult.private,
    archived: false, // Newly created notes are not archived
    content: dbResult.content,
    key: dbResult.key || null,
    links: dbResult.links as ActivityLink[] | null,
    mentions: (dbResult.mentions as string[])?.map((m) => m as ActorId) ?? [],
    tags: processedTags || {},
  };
}

export async function createNotes(
  plot: Plot,
  notes: NewNote[]
): Promise<Note[]> {
  // Create all notes in parallel, filtering out empty notes
  // Pass skipActivityRead: true to avoid deadlock from parallel activity_read upserts
  const results = await Promise.allSettled(
    notes.map((note) => createNote(plot, note, true))
  );

  // Return only successfully created notes, log failures (except empty note errors)
  return results
    .map((result, index) => {
      if (result.status === "fulfilled") {
        return result.value;
      } else {
        // Only log non-empty-note errors
        if (!result.reason?.message?.includes("fully empty note")) {
          console.error("[Plot] Failed to create note:", result.reason);
        }
        return null;
      }
    })
    .filter((note): note is Note => note !== null);
}

export async function updateActivity(
  plot: Plot,
  activity: ActivityUpdate
): Promise<void> {
  // Determine activity ID - either provided directly or looked up by source
  let activityId: string;

  if ("id" in activity && activity.id) {
    // ID provided directly
    activityId = activity.id;
  } else if ("source" in activity && activity.source) {
    // Look up activity by source
    const { data: existingActivity, error: fetchError } = await plot.supabase
      .from("activity")
      .select("id")
      .eq("source", activity.source)
      .single();

    if (fetchError || !existingActivity) {
      throw new Error(
        `Activity not found with source "${activity.source}": ${
          fetchError?.message ?? "Not found"
        }`
      );
    }

    activityId = existingActivity.id;
  } else {
    throw new Error("Activity update must provide either id or source");
  }

  // Check worker-level cache for activity data first
  const { getActivityCache } = await import("./index");
  const cacheKey = `${activityId}:${plot.priorityTwistId}`;
  const cached = getActivityCache()?.get(cacheKey);

  if (cached) {
    // Use cached data - no database query needed
    await plot.validateActivityUpdateAccess(activityId, {
      created_by: cached.created_by,
      mentions: cached.mentions,
    });

    // Validate priority access
    await plot.validatePriorityAccess(cached.priority_id);
  } else {
    // Cache miss - validate access first (will query for created_by/mentions)
    await plot.validateActivityUpdateAccess(activityId);

    // Query for priority_id to validate access
    const { data: existingActivity, error: fetchError } = await plot.supabase
      .from("activity")
      .select("priority_id")
      .eq("id", activityId)
      .single();

    if (fetchError || !existingActivity) {
      throw new Error(
        `Activity not found or access denied: ${
          fetchError?.message ?? "Not found"
        }`
      );
    }

    // Validate priority access
    await plot.validatePriorityAccess(existingActivity.priority_id);
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
  if (activity.draft !== undefined) {
    dbUpdate.draft = activity.draft;
  }
  if (activity.private !== undefined) {
    dbUpdate.private = activity.private;
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
      activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null;
  }
  if (activity.recurrenceDates !== undefined) {
    dbUpdate.recurrence_dates =
      activity.recurrenceDates?.map((d) => d.toISOString()) ?? null;
  }

  // Handle occurrence for recurring event exceptions
  if (activity.occurrence !== undefined) {
    const hasTimestamp =
      activity.start instanceof Date || activity.end instanceof Date;
    const occurrenceStr = activity.occurrence
      ? hasTimestamp
        ? activity.occurrence.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
        : activity.occurrence.toISOString().substring(0, 10) // YYYY-MM-DD
      : null;
    (dbUpdate as any).occurrence = occurrenceStr;
  }

  // Handle scheduling fields - need to calculate dbEnd and duration
  const hasSchedulingUpdate =
    activity.start !== undefined ||
    activity.end !== undefined ||
    activity.recurrenceUntil !== undefined ||
    activity.recurrenceCount !== undefined;

  if (hasSchedulingUpdate) {
    // Calculate database end and duration from SDK format
    const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

    // Set duration
    if (duration !== null) {
      dbUpdate.duration = formatInterval(duration);
    }

    // Handle scheduling range fields
    if (activity.start instanceof Date || dbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        dbEnd instanceof Date
          ? dbEnd.toISOString()
          : dbEnd
          ? `${dbEnd}T23:59:59Z`
          : null;

      if (startStr && endStr) {
        dbUpdate.at = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbUpdate.at = `[${startStr},)`;
      } else if (endStr) {
        dbUpdate.at = `(,${endStr}]`;
      }
      // Clear the date range if we're using timestamp range
      dbUpdate.on = null;
    } else if (
      activity.start !== undefined ||
      dbEnd !== undefined ||
      dbEnd !== null
    ) {
      // Date range
      const startStr = activity.start;
      const endStr = dbEnd;

      if (startStr && endStr) {
        dbUpdate.on = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbUpdate.on = `[${startStr},)`;
      } else if (endStr) {
        dbUpdate.on = `(,${endStr}]`;
      }
      // Clear the timestamp range if we're using date range
      dbUpdate.at = null;
    }
  }

  // For actions with null assignee, force at and on to null (constraint requirement)
  // This handles updates that explicitly set assignee_id to null
  if ("assignee_id" in dbUpdate && dbUpdate.assignee_id === null) {
    const hadScheduling = ("at" in dbUpdate && dbUpdate.at !== null) || ("on" in dbUpdate && dbUpdate.on !== null);
    dbUpdate.at = null;
    dbUpdate.on = null;
    if (hadScheduling) {
      console.warn(
        "[updateActivity] Update with null assignee_id had scheduling fields - nullifying at/on to satisfy constraint"
      );
    }
  }

  // Execute the update
  const { error: updateError } = await plot.supabase
    .from("activity")
    .update(dbUpdate)
    .eq("id", activityId);

  if (updateError) {
    throw new Error(`Activity update failed: ${updateError.message}`);
  }

  // Handle full tags object replacement (only for activities created by this twist or another instance of the same twist)
  if (activity.tags !== undefined) {
    // Get created_by from cache or query if needed
    const created_by =
      cached?.created_by ??
      (async () => {
        const { data: activityData, error: queryError } = await plot.supabase
          .from("activity")
          .select("created_by")
          .eq("id", activityId)
          .single();

        if (queryError || !activityData) {
          throw new Error(
            `Failed to verify activity creator: ${
              queryError?.message ?? "Not found"
            }`
          );
        }
        return activityData.created_by;
      })();

    const createdBy =
      typeof created_by === "string" || created_by === null
        ? created_by
        : await created_by;

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
      throw new Error(`Failed to delete existing tags: ${deleteError.message}`);
    }

    // Get priority_id for processing new actors
    const priorityId =
      cached?.priority_id ??
      (await (async () => {
        const { data, error } = await plot.supabase
          .from("activity")
          .select("priority_id")
          .eq("id", activityId)
          .single();

        if (error || !data) {
          throw new Error(
            `Failed to get activity priority: ${error?.message ?? "Not found"}`
          );
        }
        return data.priority_id;
      })());

    // Process tags - convert NewActor[] to ActorId[] for each tag
    const processedTags: Partial<Record<number, ActorId[]>> = {};
    for (const [tagId, newActors] of Object.entries(activity.tags)) {
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
          activity_id: activityId,
          tag_id: parseInt(tagId),
          actor_id: actorId,
          updated_by: plot.getUpdatedBy(),
          sync_depth: plot.syncDepth + 1,
        }))
      );

    if (newTags.length > 0) {
      const { error: insertError } = await plot.supabase
        .from("activity_tag")
        .insert(newTags);

      if (insertError) {
        throw new Error(`Failed to insert new tags: ${insertError.message}`);
      }
    }
  }

  // Handle twist tags separately using RPC (for adding/removing caller's own tags)
  if (activity.twistTags) {
    await plot.supabase.rpc("update_activity_tags", {
      p_activity_id: activityId,
      p_actor_id: plot.priorityTwistId,
      p_client_id: plot.getUpdatedBy(),
      p_tag_updates: activity.twistTags,
    });
  }
}

export async function updateNote(plot: Plot, note: NoteUpdate): Promise<void> {
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

  await plot.validatePriorityAccess(activityData.priority_id);

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
  if (note.draft !== undefined) {
    dbUpdate.draft = note.draft;
  }
  if (note.private !== undefined) {
    dbUpdate.private = note.private;
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

  // Execute the update
  const { error: updateError } = await plot.supabase
    .from("note")
    .update(dbUpdate)
    .eq("id", noteId);

  if (updateError) {
    throw new Error(`Note update failed: ${updateError.message}`);
  }

  // Handle tags if provided
  if (note.tags !== undefined) {
    // Delete all existing tags for this note
    const { error: deleteError } = await plot.supabase
      .from("note_tag")
      .delete()
      .eq("note_id", noteId);

    if (deleteError) {
      throw new Error(`Failed to delete existing tags: ${deleteError.message}`);
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
        draft: row.draft,
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

export async function getActivityByMeta(
  plot: Plot,
  meta: ActivityMeta,
  includeArchived = false
): Promise<Activity | null> {
  try {
    // Query activities with matching meta fields using the user_activity view
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

    // Use JSON containment for meta queries
    query = query.contains("meta", meta);

    // By default, exclude archived activities
    if (!includeArchived) {
      query = query.is("archived_at", null);
    }

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
      updated_at: data.updated_at ?? new Date().toISOString(),
      updated_by: data.updated_by ?? 0,
      author: data.author,
      assignee: data.assignee ?? null,
      assignee_id: null,
      embedding: null,
      pick_priority: null,
      active_source: null,
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

    // @ts-ignore - Type assertion needed due to complex type inference with view columns
    return fromDbActivity(
      {
        ...dataWithAuthor,
        tags: tagsData?.tags || null,
      } as any,
      includeAuthorEmail
    );
  } catch (err) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Failed to get activity by meta", err as Error);
    throw err;
  }
}

export async function createActivities(
  plot: Plot,
  activities: (NewActivity | NewActivityWithNotes)[]
): Promise<Activity[]> {
  if (activities.length === 0) {
    return [];
  }

  // Convert all activities to database format
  const dbActivities: Database["public"]["Tables"]["activity"]["Insert"][] = [];

  for (const activity of activities) {
    // Skip activity exceptions for batch operations
    if (activity.recurrence && activity.occurrence) {
      throw new Error(
        "Activity exceptions are not supported in batch creation"
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
        // Get content from first note
        const firstNoteContent =
          "notes" in activity && activity.notes?.[0]?.content
            ? activity.notes[0].content
            : null;

        const textToEmbed = [activity.title, firstNoteContent]
          .filter(Boolean)
          .join(" ");

        if (textToEmbed.trim().length > 0) {
          try {
            embedding = await plot.ai.embed(textToEmbed);
          } catch (error) {
            const logger = createLogger({
              priority_twist_id: plot.priorityTwistId,
            });
            logger.warn(
              "Failed to generate embedding for pickPriority in batch operation, falling back to default priority",
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
      // Explicit priority specified: explicit > default
      targetPriorityId =
        ("priority" in activity ? activity.priority.id : undefined) ??
        plot.priorityId;
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
          // Default to now, but respect null
          if (activity.start === undefined) {
            activity.start = new Date();
          }
          break;
        case ActivityType.Event:
          dbActivityType = "event";
          break;
      }
    }

    // Calculate database end and duration from SDK format
    const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

    // Generate preview from first note with content
    let previewText: string | null = null;
    if ("notes" in activity && activity.notes && activity.notes.length > 0) {
      // Find first note with content
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
    const authorId = activity.author
      ? await processNewActor(plot, activity.author, targetPriorityId)
      : plot.priorityTwistId;

    // Process assignee
    let assigneeId: string | null = null;
    if (activity.assignee !== undefined) {
      // assignee is explicitly provided (can be NewActor or null)
      assigneeId = await processNewActor(
        plot,
        activity.assignee,
        targetPriorityId
      );
    } else if (dbActivityType === "action") {
      // For actions without explicit assignee, default to twist owner's contact
      // Use single query with join via database function
      const result = await plot.supabase.rpc(
        "get_priority_twist_owner_contact",
        {
          p_priority_twist_id: plot.priorityTwistId,
        }
      );

      if (result.error) {
        throw new Error(`Failed to get twist owner contact: ${result.error.message}`);
      }

      if (result.data) {
        assigneeId = result.data;
      }
    }

    // Convert NewActivity to database format
    // @ts-ignore - authorId is guaranteed to be non-null from processNewActor logic
    const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
      author_id: authorId as string,
      created_by: plot.priorityTwistId,
      assignee_id: assigneeId,
      priority_id: targetPriorityId,
      type: dbActivityType,
      title:
        activity.title && activity.title.trim() !== "" ? activity.title : null,
      preview: previewText,
      duration: duration ? formatInterval(duration) : null,
      done_at: activity.done ? activity.done.toISOString() : null,
      recurrence_rule: activity.recurrenceRule ?? null,
      recurrence_exdates:
        activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null,
      recurrence_dates:
        activity.recurrenceDates?.map((d) => d.toISOString()) ?? null,
      meta: activity.meta ?? null,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      embedding: embedding ? JSON.stringify(embedding) : null,
      pick_priority: pickPriorityConfig ?? null,
    };

    // If tool provided a source, add it for upsert behavior
    if ("source" in activity && activity.source) {
      dbActivity.source = activity.source;
    }

    // Handle scheduling fields using calculated dbEnd
    if (
      (activity.start !== undefined && activity.start !== null) ||
      (dbEnd !== undefined && dbEnd !== null)
    ) {
      if (activity.start instanceof Date || dbEnd instanceof Date) {
        // Timestamp range
        const startStr =
          activity.start instanceof Date
            ? activity.start.toISOString()
            : activity.start
            ? `${activity.start}T00:00:00Z`
            : null;
        const endStr =
          dbEnd instanceof Date
            ? dbEnd.toISOString()
            : dbEnd
            ? `${dbEnd}T23:59:59Z`
            : null;

        if (startStr && endStr) {
          dbActivity.at = `[${startStr},${endStr})`;
        } else if (startStr) {
          dbActivity.at = `[${startStr},)`;
        } else if (endStr) {
          dbActivity.at = `(,${endStr}]`;
        }
      } else {
        // Date range
        const startStr = activity.start;
        const endStr = dbEnd;

        if (startStr && endStr) {
          dbActivity.on = `[${startStr},${endStr})`;
        } else if (startStr) {
          dbActivity.on = `[${startStr},)`;
        } else if (endStr) {
          dbActivity.on = `(,${endStr}]`;
        }
      }
    }

    dbActivities.push(dbActivity);
  }

  // Batch insert or upsert activities
  // Use upsert if any activities have source field to handle duplicates
  const hasAnySource = dbActivities.some((a) => a.source);
  const dbResult = safeQuery(
    hasAnySource
      ? await plot.supabase
          .from("activity")
          .upsert(dbActivities, { onConflict: "source,source_priority_root" })
          .select()
      : await plot.supabase.from("activity").insert(dbActivities).select()
  );

  // Filter activities that should be marked as read (unread === false)
  const activitiesToMarkAsRead = dbResult.filter((dbActivity, index) => {
    const originalActivity = activities[index];
    return "unread" in originalActivity && originalActivity.unread === false;
  });

  // Mark activities as read for all priority users if any activities have unread === false
  if (activitiesToMarkAsRead.length > 0) {
    // Group activities by priority_id to minimize database queries
    const activitiesByPriority = new Map<
      string,
      typeof activitiesToMarkAsRead
    >();
    for (const activity of activitiesToMarkAsRead) {
      const priorityId = activity.priority_id;
      if (!activitiesByPriority.has(priorityId)) {
        activitiesByPriority.set(priorityId, []);
      }
      activitiesByPriority.get(priorityId)!.push(activity);
    }

    // For each priority, get users and create activity_read entries
    for (const [priorityId, priorityActivities] of activitiesByPriority) {
      // Get all users with access to this priority (including inherited access from parent priorities)
      const usersResult = await plot.supabase.rpc(
        "get_users_with_priority_access",
        {
          target_priority_id: priorityId,
        }
      );

      if (usersResult.data && usersResult.data.length > 0) {
        // Create activity_read entries for all users and all activities in this priority
        const activityReadEntries = priorityActivities.flatMap((activity) =>
          usersResult.data!.map((pu) => ({
            activity_id: activity.id,
            user_id: pu.user_id,
            read_at: activity.created_at, // Use activity's created_at timestamp
          }))
        );

        if (activityReadEntries.length > 0) {
          const insertResult = await plot.supabase
            .from("activity_read")
            .upsert(activityReadEntries, { onConflict: "user_id,activity_id" });
          if (insertResult.error) {
            const logger = createLogger({
              priority_twist_id: plot.priorityTwistId,
            });
            logger.error(
              "Failed to upsert activity_read entries for batch activities",
              insertResult.error as Error,
              {
                count: activityReadEntries.length,
              }
            );
          }
        }
      }
    }
  }

  // Process tags for activities that have them - convert NewActor[] to ActorId[]
  const processedTagsArray: Array<Partial<Record<number, ActorId[]>> | null> =
    [];
  for (let i = 0; i < activities.length; i++) {
    const activity = activities[i];
    const dbActivity = dbResult[i];

    if (!activity.tags) {
      processedTagsArray.push(null);
      continue;
    }

    const processedTags: Partial<Record<number, ActorId[]>> = {};
    for (const [tagId, newActors] of Object.entries(activity.tags)) {
      if (newActors && newActors.length > 0) {
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          dbActivity.priority_id
        );
        if (actorIds.length > 0) {
          processedTags[parseInt(tagId)] = actorIds;
        }
      }
    }
    processedTagsArray.push(
      Object.keys(processedTags).length > 0 ? processedTags : null
    );
  }

  // Add tags for activities that have them
  const allTags = processedTagsArray.flatMap((processedTags, i) => {
    if (!processedTags) return [];

    const dbActivity = dbResult[i];

    // Build tag records with proper actor IDs from the processed tags object
    return Object.entries(processedTags)
      .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
      .flatMap(([tagId, actorIds]) =>
        actorIds!.map((actorId) => ({
          activity_id: dbActivity.id,
          tag_id: parseInt(tagId),
          actor_id: actorId,
          updated_by: plot.getUpdatedBy(),
          sync_depth: plot.syncDepth + 1,
        }))
      );
  });

  if (allTags.length > 0) {
    const { error: insertError } = await plot.supabase
      .from("activity_tag")
      .insert(allTags);

    if (insertError) {
      throw new Error(`Failed to insert tags: ${insertError.message}`);
    }
  }

  // Get author from cached twist actor
  const author = await plot.getActor();

  // Check if ContactAccess.Read permission is granted to include author email
  const includeAuthorEmail =
    plot.plotOptions?.contact?.access !== undefined &&
    plot.plotOptions.contact.access >= ContactAccess.Read;

  return dbResult.map((dbActivity, index) =>
    fromDbActivity(
      {
        ...dbActivity,
        tags: processedTagsArray[index] || null,
        author: {
          id: author.id,
          name: author.name ?? "",
          type: actorTypeToString(author.type),
          email: author.email ?? null,
        },
        assignee: null,
      },
      includeAuthorEmail
    )
  );
}

async function createActivityException(
  plot: Plot,
  activity: NewActivity
): Promise<Activity> {
  if (!activity.recurrence || !activity.occurrence) {
    throw new Error(
      "Activity exception requires both recurrence and occurrence"
    );
  }

  // Validate activity update access permissions (exceptions are updates to recurring activities)
  await plot.validateActivityUpdateAccess(activity.recurrence.id);

  // Fetch the recurrence activity to get priority
  const { data: recurrenceActivity, error: recurrenceError } =
    await plot.supabase
      .from("activity")
      .select("source, priority_id, priority:priority!priority_id(id, title)")
      .eq("id", activity.recurrence.id)
      .single();

  if (recurrenceError || !recurrenceActivity) {
    throw new Error("Recurrence activity not found");
  }

  // Validate access to the recurrence activity's priority
  await plot.validatePriorityAccess(recurrenceActivity.priority_id);

  // Format occurrence as required by database
  const hasTimestamp =
    activity.start instanceof Date || activity.end instanceof Date;
  const occurrenceStr = hasTimestamp
    ? activity.occurrence!.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
    : activity.occurrence!.toISOString().substring(0, 10); // YYYY-MM-DD

  // Calculate database end and duration from SDK format for exceptions
  const { dbEnd: exceptionDbEnd, duration: exceptionDuration } =
    calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

  const dbException: Database["public"]["Tables"]["activity_exception"]["Insert"] =
    {
      activity_id: activity.recurrence.id,
      occurrence: occurrenceStr,
      title:
        activity.title && activity.title.trim() !== "" ? activity.title : null,
      duration: exceptionDuration ? formatInterval(exceptionDuration) : null,
      done_at: activity.done ? activity.done.toISOString() : null,
      meta: activity.meta ?? null,
      updated_by: plot.getUpdatedBy(),
    };

  // Handle scheduling fields for exception using calculated dbEnd
  if (
    (activity.start !== undefined && activity.start !== null) ||
    (exceptionDbEnd !== undefined && exceptionDbEnd !== null)
  ) {
    if (activity.start instanceof Date || exceptionDbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        exceptionDbEnd instanceof Date
          ? exceptionDbEnd.toISOString()
          : exceptionDbEnd
          ? `${exceptionDbEnd}T23:59:59Z`
          : null;

      if (startStr && endStr) {
        dbException.at = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbException.at = `[${startStr},)`;
      } else if (endStr) {
        dbException.at = `(,${endStr}]`;
      }
    } else {
      // Date range
      const startStr = activity.start;
      const endStr = exceptionDbEnd;

      if (startStr && endStr) {
        dbException.on = `[${startStr},${endStr}]`;
      } else if (startStr) {
        dbException.on = `[${startStr},)`;
      } else if (endStr) {
        dbException.on = `(,${endStr}]`;
      }
    }
  }

  const result = await plot.supabase
    .from("activity_exception")
    .insert(dbException)
    .select()
    .single();

  if (result.error) {
    throw new Error(
      `Activity exception creation failed: ${result.error.message}`
    );
  }

  // Return as Activity with exception fields
  return {
    id: result.data.id as Uuid,
    source: recurrenceActivity.source,
    created: new Date(result.data.created_at),
    type: activity.type || ActivityType.Note,
    author: activity.recurrence!.author,
    start: activity.start ?? null,
    end: activity.end ?? null,
    recurrenceUntil: activity.recurrenceUntil ?? null,
    recurrenceCount: activity.recurrenceCount ?? null,
    done: activity.done ?? null,
    title: activity.title ?? "",
    assignee: null,
    draft: false,
    private: false,
    archived: result.data.archived_at !== null,
    priority: {
      id: recurrenceActivity.priority_id,
      title: (recurrenceActivity.priority as any)?.title ?? "Untitled",
    },
    recurrenceRule: null,
    recurrenceExdates: null,
    recurrenceDates: null,
    recurrence: activity.recurrence ?? null,
    occurrence: activity.occurrence ?? null,
    meta: activity.meta ?? null,
    tags: {}, // Tags not available for exceptions
    mentions: [], // Read-only aggregation from notes
  };
}
