import type { Json } from "@plotday/db";
import type { Link, LinkUpdate, Note, NewLinkWithNotes, Uuid, ActorId } from "@plotday/twister/plot";
import { ActorType } from "@plotday/twister/plot";
import type { LinkFilter } from "@plotday/twister/tools/plot";
import { LinkAccess } from "@plotday/twister/tools/plot";

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
      // Use thread.key for database-level dedup: concurrent createLink calls
      // for the same source will upsert the same thread instead of creating
      // duplicates. relatedSource takes precedence so related links share a thread.
      ...(hasSource
        ? { key: link.relatedSource ?? (link as any).source }
        : {}),
      ...(link.author ? { author: link.author } : {}),
      ...(link.assignee !== undefined ? { assignee: link.assignee } : {}),
      ...(link.meta !== undefined ? { meta: link.meta } : {}),
      ...(link.actions !== undefined ? { actions: link.actions } : {}),
      ...(link.created ? { created: link.created } : {}),
      ...(link.private !== undefined ? { private: link.private } : {}),
      ...(link.unread !== undefined ? { unread: link.unread } : {}),
      ...(link.archived !== undefined ? { archived: link.archived } : {}),
      ...(link.preview !== undefined ? { preview: link.preview } : {}),
      ...(link.priority ? { priority: link.priority } : {}),
      ...(link.pickPriority !== undefined
        ? { pickPriority: link.pickPriority }
        : {}),
      ...(link.notes ? { notes: link.notes } : {}),
    };

    // For source-based links, look up existing link to reuse its thread.
    // This handles reconnection: when a source is archived (threads archived)
    // and reinstalled, the existing thread is found and unarchived by upsert_thread.
    // Single query combines exact source match, relatedSource match, and reverse match
    // with priority ordering via CASE expression.
    const priorityRootFilter = sql<boolean>`link.source_priority_root = (SELECT subpath(path, 0, 1) FROM priority WHERE id = ${plot.priorityId})`;

    if (hasSource && !threadData.id) {
      const sourceValue = (link as any).source as string;
      const relatedSourceValue = link.relatedSource ?? null;

      const existingLink = await plot.db
        .selectFrom("link")
        .select("link.thread_id")
        .where(priorityRootFilter)
        .where((eb) =>
          eb.or([
            eb("link.source", "=", sourceValue),
            ...(relatedSourceValue
              ? [eb("link.source", "=", relatedSourceValue)]
              : []),
            eb("link.related_source", "=", sourceValue),
          ])
        )
        .orderBy(
          relatedSourceValue
            ? sql`CASE
                WHEN link.source = ${sourceValue} THEN 0
                WHEN link.source = ${relatedSourceValue} THEN 1
                ELSE 2
              END`
            : sql`CASE
                WHEN link.source = ${sourceValue} THEN 0
                ELSE 2
              END`
        )
        .limit(1)
        .executeTakeFirst();

      if (existingLink) {
        threadData.id = existingLink.thread_id;
      }
    }

    // Look up twist_id for icon — passed to threadData so createThread skips its own lookup
    const ptRow = await plot.db
      .selectFrom("priority_twist")
      .select("twist_id")
      .where("id", "=", plot.priorityTwistId)
      .executeTakeFirst();
    if (ptRow) {
      threadData.icon = link.type
        ? `connector:${ptRow.twist_id}:${link.type}`
        : `connector:${ptRow.twist_id}`;
    }

    let { id: threadId, priorityId: threadPriorityId } = await createThread(plot, threadData);

    // Step 2: Create the link row (priority_id returned from createThread)

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
        threadPriorityId
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
      ...(link.relatedSource !== undefined
        ? { related_source: link.relatedSource }
        : {}),
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
      if (link.relatedSource !== undefined)
        linkUpsert.related_source = link.relatedSource;

      const userId = await plot.getUserId();
      const linkResult = await rpcUser(plot.db, "upsert_link", {
        user_id: userId,
        p_link: linkUpsert as Json,
        p_defaults: linkDefaults as Json,
      });
      linkId = linkResult.id;

      // If the link was already associated with a different thread (race condition
      // where concurrent saveLink calls for the same source each create a thread),
      // clean up the orphaned thread we just created and use the existing one.
      if (linkResult.thread_id && linkResult.thread_id !== threadId) {
        await plot.db
          .deleteFrom("thread")
          .where("id", "=", threadId)
          .execute();
        threadId = linkResult.thread_id as Uuid;
      }

      // Post-insert reconciliation for relatedSource race conditions.
      // If this link has relatedSource and the related link is on a different thread,
      // move this link to the related link's thread.
      if (link.relatedSource) {
        const relatedLink = await plot.db
          .selectFrom("link")
          .select(["link.thread_id"])
          .where("link.source", "=", link.relatedSource)
          .where("link.thread_id", "!=", threadId)
          .where(priorityRootFilter)
          .executeTakeFirst();

        if (relatedLink?.thread_id) {
          const oldThreadId = threadId;
          threadId = relatedLink.thread_id as Uuid;
          await plot.db
            .updateTable("link")
            .set({ thread_id: threadId })
            .where("id", "=", linkId)
            .execute();
          // Delete orphaned thread if no other links reference it
          const remaining = await plot.db
            .selectFrom("link")
            .select("link.id")
            .where("link.thread_id", "=", oldThreadId)
            .executeTakeFirst();
          if (!remaining) {
            await plot.db
              .deleteFrom("thread")
              .where("id", "=", oldThreadId)
              .execute();
          }
        }
      }

      // Reverse reconciliation: move links whose related_source matches this
      // link's source to this thread.
      {
        const reverseLinks = await plot.db
          .selectFrom("link")
          .select(["link.id", "link.thread_id"])
          .where("link.related_source", "=", (link as any).source as string)
          .where("link.thread_id", "!=", threadId)
          .where(priorityRootFilter)
          .execute();

        for (const rl of reverseLinks) {
          const oldThreadId = rl.thread_id;
          await plot.db
            .updateTable("link")
            .set({ thread_id: threadId })
            .where("id", "=", rl.id)
            .execute();
          // Delete orphaned thread if no other links reference it
          const remaining = await plot.db
            .selectFrom("link")
            .select("link.id")
            .where("link.thread_id", "=", oldThreadId!)
            .executeTakeFirst();
          if (!remaining) {
            await plot.db
              .deleteFrom("thread")
              .where("id", "=", oldThreadId!)
              .execute();
          }
        }
      }
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
        threadPriorityId,
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
      ...(link.relatedSource !== undefined
        ? { related_source: link.relatedSource }
        : {}),
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
      if (link.relatedSource !== undefined)
        linkUpsert.related_source = link.relatedSource;

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

  // Batch-fetch all notes for the links' threads in a single query
  const threadIds = links
    .map((r) => r.thread_id)
    .filter((id): id is string => id != null);

  const allNoteRows =
    threadIds.length > 0
      ? await plot.db
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
          .where("note.thread_id", "in", threadIds)
          .where("note.draft", "=", false)
          .where("note.archived_at", "is", null)
          .orderBy("note.created_at", "asc")
          .execute()
      : [];

  // Group notes by thread_id
  const notesByThread = new Map<string, typeof allNoteRows>();
  for (const n of allNoteRows) {
    const tid = n.thread_id!;
    let arr = notesByThread.get(tid);
    if (!arr) {
      arr = [];
      notesByThread.set(tid, arr);
    }
    arr.push(n);
  }

  const results: Array<{ link: Link; notes: Note[] }> = [];

  for (const row of links) {
    const link: Link = {
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
      relatedSource: null,
    };

    const noteRows = (row.thread_id ? notesByThread.get(row.thread_id) : null) ?? [];
    const notes: Note[] = noteRows.map((n) => ({
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

    results.push({ link, notes });
  }

  return results;
}

/**
 * Updates a link. Currently supports moving a link to a different thread
 * by changing its thread_id.
 *
 * Requires LinkAccess.Full.
 */
export async function updateLink(
  plot: Plot,
  link: LinkUpdate
): Promise<void> {
  plot.requireLinkAccess(LinkAccess.Full);

  // Verify the link exists and is within scope
  const existingLink = await plot.db
    .selectFrom("link")
    .select(["id", "thread_id"])
    .where("id", "=", link.id)
    .executeTakeFirst();

  if (!existingLink) {
    throw new Error(`Link not found: ${link.id}`);
  }

  // Verify the link's current thread is within the twist's priority scope
  if (existingLink.thread_id) {
    const currentThread = await plot.db
      .selectFrom("thread")
      .select("priority_id")
      .where("id", "=", existingLink.thread_id)
      .executeTakeFirst();
    if (currentThread) {
      await plot.validatePriorityAccess(currentThread.priority_id);
    }
  }

  if (link.threadId !== undefined) {
    // Verify target thread exists and is within scope
    const targetThread = await plot.db
      .selectFrom("thread")
      .select("priority_id")
      .where("id", "=", link.threadId)
      .executeTakeFirst();

    if (!targetThread) {
      throw new Error(`Target thread not found: ${link.threadId}`);
    }
    await plot.validatePriorityAccess(targetThread.priority_id);

    await plot.db
      .updateTable("link")
      .set({
        thread_id: link.threadId,
        updated_by: plot.getUpdatedBy() as any,
      })
      .where("id", "=", link.id)
      .execute();
  }
}
