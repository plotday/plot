import type { Json } from "@plotday/db";
import type { Link, Note, NewLinkWithNotes, Uuid, ActorId } from "@plotday/twister/plot";
import { ActorType } from "@plotday/twister/plot";
import type { LinkFilter } from "@plotday/twister/tools/plot";

import { sql } from "kysely";
import { rpcUser } from "../../../rpc";
import {
  handleDbOperationError,
  processNewActor,
  createPreviewFromMarkdown,
  convertNoteToMarkdown,
} from "./thread-helpers";
import { createThread } from "./thread";
import { createLinkSchedules } from "./schedule";
import type { Plot } from "./index";

/**
 * Creates a link with its thread container.
 * During expand phase, this creates both a thread (with all legacy fields for backward compat)
 * and a link row (with the new link-specific fields).
 *
 * @param plot - The Plot instance
 * @param link - The link with notes to create
 * @returns The thread ID (links are accessed via their thread)
 */
export async function createLink(
  plot: Plot,
  link: NewLinkWithNotes
): Promise<Uuid> {
  try {
    // Step 1: Create the thread (backward compat)
    // Convert link fields to thread fields for legacy thread creation
    const hasSource = "source" in link && link.source;

    const threadData: any = {
      title: link.title,
      ...(hasSource ? { source: (link as any).source } : {}),
      ...("id" in link && link.id ? { id: link.id } : {}),
      ...(link.author ? { author: link.author } : {}),
      ...(link.assignee !== undefined ? { assignee: link.assignee } : {}),
      ...(link.meta !== undefined ? { meta: link.meta } : {}),
      ...(link.actions !== undefined ? { actions: link.actions } : {}),
      ...(link.created ? { created: link.created } : {}),
      ...(link.unread !== undefined ? { unread: link.unread } : {}),
      ...(link.archived !== undefined ? { archived: link.archived } : {}),
      ...(link.preview !== undefined ? { preview: link.preview } : {}),
      ...(link.priority ? { priority: link.priority } : {}),
      ...(link.pickPriority !== undefined
        ? { pickPriority: link.pickPriority }
        : {}),
      ...(link.notes ? { notes: link.notes } : {}),
      ...(link.schedules ? { schedules: link.schedules } : {}),
      ...(link.scheduleOccurrences
        ? { scheduleOccurrences: link.scheduleOccurrences }
        : {}),
      // Map status to done for backward compat
      ...(link.status === "done" ? { done: new Date() } : {}),
    };

    // For source-based links, look up existing link to reuse its thread.
    // This handles reconnection: when a source is archived (threads archived)
    // and reinstalled, the existing thread is found and unarchived by upsert_thread.
    if (hasSource && !threadData.id) {
      const existingLink = await plot.db
        .selectFrom("link")
        .select("link.thread_id")
        .where("link.source", "=", (link as any).source as string)
        .where(
          sql<boolean>`link.source_priority_root = (SELECT subpath(path, 0, 1) FROM priority WHERE id = ${plot.priorityId})`
        )
        .executeTakeFirst();

      if (existingLink) {
        threadData.id = existingLink.thread_id;
      }
    }

    const threadId = await createThread(plot, threadData);

    // Step 2: Create the link row
    // Read back the thread to get priority_id
    const thread = await plot.db
      .selectFrom("thread")
      .select(["priority_id"])
      .where("id", "=", threadId)
      .executeTakeFirstOrThrow();

    // Generate preview for link
    let previewText: string | null = null;
    if (link.preview !== undefined) {
      previewText =
        link.preview === null ? null : createPreviewFromMarkdown(link.preview);
    } else if (link.notes && link.notes.length > 0) {
      const firstNoteWithContent = link.notes.find((note) => note.content);
      if (firstNoteWithContent?.content) {
        const markdown = await convertNoteToMarkdown(
          plot.env.AI,
          firstNoteWithContent.content,
          firstNoteWithContent.contentType
        );
        previewText = createPreviewFromMarkdown(markdown);
      }
    }

    // Resolve assignee for the link (may already be processed by createThread, but idempotent)
    let assigneeId: string | null | undefined = undefined;
    if (link.assignee !== undefined) {
      assigneeId = await processNewActor(
        plot,
        link.assignee,
        thread.priority_id
      );
    }

    // Build link defaults (all fields for INSERT)
    const linkDefaults: Record<string, any> = {
      thread_id: threadId,
      created_by: plot.priorityTwistId,
      author_id: plot.priorityTwistId,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      source_created_at:
        link.created?.toISOString() ?? new Date().toISOString(),
      title: link.title,
      ...(previewText !== null ? { preview: previewText } : {}),
      ...(assigneeId !== undefined ? { assignee_id: assigneeId } : {}),
      ...(link.type !== undefined ? { type: link.type } : {}),
      ...(link.status !== undefined ? { status: link.status } : {}),
      ...(link.actions !== undefined
        ? { actions: link.actions as Json | null }
        : {}),
      ...(link.meta !== undefined
        ? { meta: link.meta as Json | null }
        : {}),
      ...(link.sourceUrl !== undefined ? { source_url: link.sourceUrl } : {}),
      ...(link.pickPriority !== undefined
        ? { match: link.pickPriority as Json | null }
        : {}),
      ...(link.channelId !== undefined ? { channel_id: link.channelId } : {}),
    };

    let linkId: string;

    if (hasSource) {
      // Build upsert fields (only explicitly provided values for UPDATE)
      const linkUpsert: Record<string, any> = {
        source: (link as any).source,
        thread_id: threadId,
        updated_by: plot.getUpdatedBy(),
        sync_depth: plot.syncDepth + 1,
      };

      if (link.title !== undefined) linkUpsert.title = link.title;
      if (link.preview !== undefined) linkUpsert.preview = previewText;
      if (link.type !== undefined) linkUpsert.type = link.type;
      if (link.status !== undefined) linkUpsert.status = link.status;
      if (link.meta !== undefined)
        linkUpsert.meta = link.meta as Json | null;
      if (link.actions !== undefined)
        linkUpsert.actions = link.actions as Json | null;
      if (assigneeId !== undefined) linkUpsert.assignee_id = assigneeId;
      if (link.sourceUrl !== undefined) linkUpsert.source_url = link.sourceUrl;
      if (link.channelId !== undefined) linkUpsert.channel_id = link.channelId;

      const userId = await plot.getUserId();
      const linkResult = await rpcUser(plot.db, "upsert_link", {
        user_id: userId,
        p_link: linkUpsert as Json,
        p_defaults: linkDefaults as Json,
      });
      linkId = linkResult.id;
    } else {
      // Plain insert for links without source
      const linkResult = await plot.db
        .insertInto("link")
        // @ts-ignore - Type mismatch between builder and actual values
        .values({
          thread_id: threadId,
          created_by: linkDefaults.created_by,
          author_id: linkDefaults.author_id,
          updated_by: linkDefaults.updated_by,
          sync_depth: linkDefaults.sync_depth,
          source_created_at: linkDefaults.source_created_at,
          title: linkDefaults.title,
          preview: linkDefaults.preview ?? null,
          assignee_id: assigneeId ?? null,
          type: link.type ?? null,
          status: link.status ?? null,
          actions: (link.actions ?? null) as Json | null,
          meta: (link.meta ?? null) as Json | null,
          source_url: link.sourceUrl ?? null,
          channel_id: link.channelId ?? null,
          match: linkDefaults.match ?? null,
        })
        .returning("id")
        .executeTakeFirstOrThrow();
      linkId = linkResult.id;
    }

    // Create link schedules if present
    if (link.schedules?.length || link.scheduleOccurrences?.length) {
      await createLinkSchedules(
        plot,
        linkId,
        thread.priority_id,
        link.schedules,
        link.scheduleOccurrences
      );
    }

    return threadId;
  } catch (error) {
    handleDbOperationError(error, "createLink", plot.priorityTwistId, {
      has_notes: !!link.notes?.length,
      has_source: "source" in link && !!(link as any).source,
    });
  }
}

/**
 * Creates a link row without creating a thread.
 * Used when create_threads is false on a source channel.
 * The link is associated directly with a priority via link.priority_id.
 *
 * @param plot - The Plot instance
 * @param link - The link to create
 * @returns The link ID
 */
export async function createLinkOnly(
  plot: Plot,
  link: NewLinkWithNotes
): Promise<Uuid> {
  try {
    const hasSource = "source" in link && link.source;

    // Resolve assignee
    let assigneeId: string | null | undefined = undefined;
    if (link.assignee !== undefined) {
      assigneeId = await processNewActor(
        plot,
        link.assignee,
        plot.priorityId
      );
    }

    // Generate preview
    let previewText: string | null = null;
    if (link.preview !== undefined) {
      previewText =
        link.preview === null ? null : createPreviewFromMarkdown(link.preview);
    } else if (link.notes && link.notes.length > 0) {
      const firstNoteWithContent = link.notes.find((note) => note.content);
      if (firstNoteWithContent?.content) {
        const markdown = await convertNoteToMarkdown(
          plot.env.AI,
          firstNoteWithContent.content,
          firstNoteWithContent.contentType
        );
        previewText = createPreviewFromMarkdown(markdown);
      }
    }

    const linkValues: Record<string, any> = {
      thread_id: null,
      priority_id: plot.priorityId,
      created_by: plot.priorityTwistId,
      author_id: plot.priorityTwistId,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      source_created_at:
        link.created?.toISOString() ?? new Date().toISOString(),
      title: link.title,
      preview: previewText,
      assignee_id: assigneeId ?? null,
      type: link.type ?? null,
      status: link.status ?? null,
      actions: (link.actions ?? null) as Json | null,
      meta: (link.meta ?? null) as Json | null,
      source_url: link.sourceUrl ?? null,
      channel_id: link.channelId ?? null,
      match: link.pickPriority ?? null,
    };

    if (hasSource) {
      // Upsert by source + source_priority_root
      const linkUpsert: Record<string, any> = {
        source: (link as any).source,
        updated_by: plot.getUpdatedBy(),
        sync_depth: plot.syncDepth + 1,
      };

      if (link.title !== undefined) linkUpsert.title = link.title;
      if (link.preview !== undefined) linkUpsert.preview = previewText;
      if (link.type !== undefined) linkUpsert.type = link.type;
      if (link.status !== undefined) linkUpsert.status = link.status;
      if (link.meta !== undefined)
        linkUpsert.meta = link.meta as Json | null;
      if (link.actions !== undefined)
        linkUpsert.actions = link.actions as Json | null;
      if (assigneeId !== undefined) linkUpsert.assignee_id = assigneeId;
      if (link.sourceUrl !== undefined) linkUpsert.source_url = link.sourceUrl;
      if (link.channelId !== undefined) linkUpsert.channel_id = link.channelId;

      const userId = await plot.getUserId();
      const linkResult = await rpcUser(plot.db, "upsert_link", {
        user_id: userId,
        p_link: linkUpsert as Json,
        p_defaults: linkValues as Json,
      });
      return linkResult.id as Uuid;
    } else {
      const linkResult = await plot.db
        .insertInto("link")
        // @ts-ignore - Type mismatch between builder and actual values
        .values(linkValues)
        .returning("id")
        .executeTakeFirstOrThrow();
      return linkResult.id as Uuid;
    }
  } catch (error) {
    handleDbOperationError(error, "createLinkOnly", plot.priorityTwistId, {
      has_source: "source" in link && !!(link as any).source,
    });
  }
}

/**
 * Queries links from connected source channels for this twist.
 * Returns links with their associated notes.
 */
export async function getLinks(
  plot: Plot,
  filter?: LinkFilter
): Promise<Array<{ link: Link; notes: Note[] }>> {
  // Get connected channel info
  let query = plot.db
    .selectFrom("priority_twist_channel")
    .innerJoin("link", (join) =>
      join
        .onRef("link.created_by", "=", "priority_twist_channel.source_priority_twist_id")
        .onRef("link.channel_id", "=", "priority_twist_channel.channel_id")
    )
    .leftJoin("actor as author", "author.id", "link.author_id")
    .leftJoin("actor as assignee", "assignee.id", "link.assignee_id")
    .select([
      "link.id",
      "link.thread_id",
      "link.source",
      "link.source_created_at",
      "link.created_at",
      "link.title",
      "link.preview",
      "link.type",
      "link.status",
      "link.actions",
      "link.meta",
      "link.source_url",
      "link.channel_id",
      "link.author_id",
      "link.assignee_id",
      "author.name as author_name",
      "author.type as author_type",
      "assignee.name as assignee_name",
      "assignee.type as assignee_type",
    ])
    .where("priority_twist_channel.priority_twist_id", "=", plot.priorityTwistId)
    .where("priority_twist_channel.enabled", "=", true)
    .orderBy("link.created_at", "desc");

  if (filter?.channelIds?.length) {
    query = query.where("link.channel_id", "in", filter.channelIds);
  }
  if (filter?.since) {
    query = query.where("link.created_at", ">", filter.since.toISOString() as any);
  }
  if (filter?.type) {
    query = query.where("link.type", "=", filter.type);
  }

  const limit = filter?.limit ?? 50;
  const links = await query.limit(limit).execute();

  // Fetch notes for each link's thread in parallel
  const results: Array<{ link: Link; notes: Note[] }> = [];

  for (const row of links) {
    const link: Link = {
      id: row.id as Uuid,
      threadId: row.thread_id as Uuid,
      source: row.source,
      created: row.source_created_at
        ? new Date(row.source_created_at)
        : new Date(row.created_at),
      author: row.author_id
        ? {
            id: row.author_id as ActorId,
            name: row.author_name ?? null,
            type:
              row.author_type === "user"
                ? ActorType.User
                : row.author_type === "priority_twist"
                ? ActorType.Twist
                : ActorType.Contact,
          }
        : null,
      title: row.title || "",
      preview: row.preview,
      assignee: row.assignee_id
        ? {
            id: row.assignee_id as ActorId,
            name: row.assignee_name ?? null,
            type:
              row.assignee_type === "user"
                ? ActorType.User
                : row.assignee_type === "priority_twist"
                ? ActorType.Twist
                : ActorType.Contact,
          }
        : null,
      type: row.type,
      status: row.status,
      actions: row.actions as any,
      meta: row.meta as any,
      sourceUrl: row.source_url,
      channelId: row.channel_id ?? null,
    };

    // Fetch notes for this link's thread
    let notes: Note[] = [];
    if (row.thread_id) {
      const noteRows = await plot.db
        .selectFrom("note")
        .leftJoin("actor", "actor.id", "note.author_id")
        .select([
          "note.id",
          "note.created_at",
          "note.thread_id",
          "note.author_id",
          "note.created_by",
          "note.content",
          "note.key",
          "note.re_note_id",
          "note.mentions",
          "note.private",
          "note.archived_at",
          "note.actions",
          "actor.name as author_name",
          "actor.type as author_type",
        ])
        .where("note.thread_id", "=", row.thread_id)
        .where("note.draft", "=", false)
        .where("note.archived_at", "is", null)
        .orderBy("note.created_at", "asc")
        .execute();

      notes = noteRows.map((n) => ({
        id: n.id as Uuid,
        created: n.created_at ? new Date(n.created_at) : new Date(),
        // @ts-ignore - Partial Thread data
        thread: { id: n.thread_id } as any,
        author: {
          id: (n.author_id ?? n.created_by) as ActorId,
          name: n.author_name ?? null,
          type:
            n.author_type === "user"
              ? ActorType.User
              : n.author_type === "priority_twist"
              ? ActorType.Twist
              : ActorType.Contact,
        },
        content: n.content,
        key: n.key || null,
        reNote: n.re_note_id ? { id: n.re_note_id as Uuid } : null,
        mentions: (n.mentions as ActorId[]) || [],
        tags: {},
        private: n.private ?? false,
        archived: n.archived_at !== null,
        actions: n.actions as any,
      }));
    }

    results.push({ link, notes });
  }

  return results;
}
