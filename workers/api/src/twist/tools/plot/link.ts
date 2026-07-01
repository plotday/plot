import type { Json } from "@plotday/db";
import type { Link, LinkUpdate, Note, NewLinkWithNotes, Uuid, ActorId } from "@plotday/twister/plot";
import { ActorType } from "@plotday/twister/plot";
import type { LinkFilter } from "@plotday/twister/tools/plot";
import { LinkAccess } from "@plotday/twister/tools/plot";

import { sql, type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../../../db-types";
import { withUserDb } from "../../../db";
import { rpcUser } from "../../../rpc";
import { applyMuteForNewThread } from "../../../state/mute";
import {
  handleDbOperationError,
  prepareThreadForDb,
  processNewActor,
  createPreviewFromMarkdown,
  convertNoteToMarkdown,
  ThreadFilingSkippedError,
} from "./thread-helpers";
import {
  createThread,
  markThreadReadForOwner,
  markThreadUnreadForUsers,
} from "./thread";
import { createNotes } from "./note";
import { normalizeConferencingLink } from "./conferencing";
import { createLinkSchedules } from "./schedule";
import type { Plot } from "./index";

/**
 * Remove an orphan thread left behind by saveLink dedup/merge. Archive-first
 * (syncs to clients via thread.archived_at, frees the (twist_id, key) slot)
 * UNLESS the thread is a genuinely-never-synced ephemeral race orphan — no
 * notes and no non-revoked thread_priority — in which case a hard delete
 * avoids leaving server cruft (nothing was ever synced to strand).
 */
async function archiveOrDeleteOrphanThread(
  plot: Plot,
  threadId: Uuid,
  db: Kysely<DB> = plot.db
): Promise<void> {
  const hasNote = await db
    .selectFrom("note").select("note.id")
    .where("note.thread_id", "=", threadId as string)
    .limit(1).executeTakeFirst();
  const hasFiling = await db
    .selectFrom("thread_priority").select("thread_priority.thread_id")
    .where("thread_priority.thread_id", "=", threadId as string)
    .where("thread_priority.revoked_at", "is", null)
    .limit(1).executeTakeFirst();
  if (!hasNote && !hasFiling) {
    await db.deleteFrom("thread").where("id", "=", threadId as string).execute();
    return;
  }
  await db
    .updateTable("thread")
    .set({ archived_at: new Date().toISOString() })
    .where("id", "=", threadId as string)
    .where("archived_at", "is", null)
    .execute();
}

/**
 * Creates a link with its thread container.
 * During expand phase, this creates both a thread (with all legacy fields for backward compat)
 * and a link row (with the new link-specific fields).
 *
 * @param plot - The Plot instance
 * @param link - The link with notes to create
 * @returns The thread ID (links are accessed via their thread)
 */
/**
 * Canonical source array for a link: `sources` plus the legacy `source` /
 * `relatedSource` fields, de-duplicated. The thread dedup key is the sorted
 * minimum of this array (see `createLink`). Exported so the auto-threading
 * chokepoint (`Integrations.saveLink`) derives the same `messageSource` the
 * link will key its thread on.
 */
export function linkSources(link: NewLinkWithNotes): string[] {
  return Array.from(
    new Set(
      [
        ...(((link as any).sources as string[] | undefined) ?? []),
        ...((link as any).source ? [(link as any).source as string] : []),
        ...(link.relatedSource ? [link.relatedSource] : []),
      ].filter((s): s is string => Boolean(s))
    )
  );
}

/** The link's primary (thread-key) source: sorted minimum of {@link linkSources}. */
export function linkPrimarySource(link: NewLinkWithNotes): string | null {
  const sources = linkSources(link);
  return sources.length > 0 ? [...sources].sort()[0] : null;
}

export type CreateLinkOptions = {
  /**
   * Auto-threading fold target: the canonical source of the conversation's
   * anchor thread, chosen once at ingest by the resolver (see
   * ./auto-thread.ts). When set and an anchor thread keyed by it already
   * exists, this link's notes attach to that thread — preserving its title —
   * instead of creating a new thread. The link keeps its OWN source for note
   * identity. Falls back to a normal new thread when no anchor thread exists
   * yet (the conservative default; also the self-heal for out-of-order sync).
   */
  threadKey?: string;
};

export async function createLink(
  plot: Plot,
  link: NewLinkWithNotes,
  opts?: CreateLinkOptions
): Promise<Uuid> {
  try {
    // Reconcile conferencing links that arrive in the location field (e.g. a
    // Zoom/Meet/Teams URL pasted into a calendar event's location) into a
    // single conferencing action, clearing the duplicate URL from
    // meta.location. Done up front so both the thread (legacy) and link rows
    // persist the normalized values. See ./conferencing.ts.
    const normalizedConferencing = normalizeConferencingLink({
      meta: link.meta,
      actions: link.actions,
    });
    link.meta = normalizedConferencing.meta;
    link.actions = normalizedConferencing.actions;

    // Normalize identifiers to a single canonical array. Connectors may supply
    // `sources` directly, or the legacy `source` + `relatedSource` pair; the
    // runtime treats them all as elements of `sources` for upsert/bundling.
    const sourcesArray: string[] = linkSources(link);
    // Primary source for the legacy `source` column + thread.key dedup. Pick
    // the sorted minimum so concurrent connectors that agree on at least one
    // canonical alias compute the same key cross-user.
    const primarySource: string | null = linkPrimarySource(link);

    // Step 1: Create the thread (backward compat)
    // Convert link fields to thread fields for legacy thread creation
    const hasSource = sourcesArray.length > 0;

    const threadData: any = {
      title: link.title,
      ...(hasSource ? { source: primarySource } : {}),
      // Use thread.key for database-level dedup: concurrent createLink calls
      // that share any canonical alias converge on the same thread.
      ...(hasSource ? { key: primarySource } : {}),
      ...(link.author ? { author: link.author } : {}),
      ...(link.assignee !== undefined ? { assignee: link.assignee } : {}),
      ...(link.meta !== undefined ? { meta: link.meta } : {}),
      ...(link.facets !== undefined ? { facets: link.facets } : {}),
      ...(link.actions !== undefined ? { actions: link.actions } : {}),
      ...(link.created ? { created: link.created } : {}),
      ...(link.access !== undefined ? { access: link.access } : {}),
      ...(link.accessContacts !== undefined ? { accessContacts: link.accessContacts } : {}),
      ...(link.unread !== undefined ? { unread: link.unread } : {}),
      ...(link.archived !== undefined ? { archived: link.archived } : {}),
      ...(link.preview !== undefined ? { preview: link.preview } : {}),
      ...(link.focus ? { focus: link.focus } : {}),
      // Notes are created AFTER the link row exists (see createNotes call
      // later in this function) so note.link_id can be set on the first write.
    };

    // Look up twist_id for icon + cross-user link lookup scope.
    const ptRow = await plot.db
      .selectFrom("twist_instance")
      .select("twist_id")
      .where("id", "=", plot.twistInstanceId)
      .executeTakeFirst();
    if (ptRow) {
      threadData.icon = link.type
        ? `connector:${ptRow.twist_id}:${link.type}`
        : `connector:${ptRow.twist_id}`;
      // Pass twist_id to upsert_thread so it can dedupe cross-user on
      // (twist_id, key). Server-only field — users cannot set it.
      threadData.twist_id = ptRow.twist_id;
    }

    // Auto-threading fold: when the resolver chose an anchor (a different
    // conversation root), attach this link's notes to that anchor thread —
    // keyed globally by (twist_id, key=anchorSource) — instead of creating a
    // new one. Omit the title so upsert_thread preserves the anchor thread's
    // title (this message folds in as a note, not a rename). Only fold when
    // the anchor thread actually exists; otherwise fall through to a normal
    // new thread keyed by this message's own source (the conservative default,
    // and the self-heal for out-of-order processing).
    if (
      opts?.threadKey &&
      hasSource &&
      opts.threadKey !== primarySource &&
      threadData.twist_id != null &&
      !threadData.id
    ) {
      const anchorThread = await plot.db
        .selectFrom("thread")
        .select("id")
        .where("twist_id", "=", threadData.twist_id)
        .where("key", "=", opts.threadKey)
        .where("archived_at", "is", null)
        .executeTakeFirst();
      if (anchorThread) {
        threadData.id = anchorThread.id;
        delete threadData.title;
      }
    }

    if (hasSource && !threadData.id) {
      // Global cross-connector co-location: match by canonical `sources`
      // overlap across ALL connectors (the documented intent of `sources`),
      // scoped to this user's priority root so we never bundle across users.
      // Note-scoped links (e.g. Granola) participate so a later canonical
      // sync lands on the augmenter-created thread. thread_id must be non-null.
      const priorityRoot = await plot.getPriorityRoot();
      const existingLink = await plot.db
        .selectFrom("link")
        .select("link.thread_id")
        .where("link.source_priority_root", "=", priorityRoot)
        .where(sql<boolean>`link.sources && ${sql.val(sourcesArray)}::text[]`)
        .where("link.thread_id", "is not", null)
        .where("link.archived_at", "is", null)
        .orderBy("link.created_at", "asc")
        .limit(1)
        .executeTakeFirst();

      if (existingLink?.thread_id) {
        threadData.id = existingLink.thread_id;
      }
    }

    // Prepare the thread row (classification, embedding, author resolution —
    // all network/read work) on plot.db, OUTSIDE the write transaction. Holding
    // a pooled connection across these calls is the pool-pressure anti-pattern
    // that stranded orphan thread shells in the first place. The committed
    // thread+link write happens together in the transaction below.
    const prepared = await prepareThreadForDb(plot, threadData);
    if (!prepared) {
      // Team-connector thread with no matching team priority for this user.
      // saveLink catches ThreadFilingSkippedError and returns null (matches
      // createThread's behavior).
      throw new ThreadFilingSkippedError();
    }

    // Pre-warm the memoized owner lookup so nothing inside the transaction
    // queries plot.db (a single-connection pool) for it — that would deadlock
    // against the connection the transaction holds.
    const userId = await plot.getUserId();

    // Generate the link preview (may invoke AI for HTML notes) outside the txn.
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

    // Resolve assignee outside the txn: processNewActor → addContacts opens its
    // OWN connection/transaction, which must not nest inside ours. Scope new
    // contacts to the thread's resolved priority (same value createThread uses).
    let assigneeId: string | null | undefined = undefined;
    if (link.assignee !== undefined) {
      assigneeId = await processNewActor(plot, link.assignee, prepared.priorityId);
    }

    // Commit the thread row and the link row in ONE transaction so a mid-save
    // failure rolls the thread back instead of leaving an orphan shell (a thread
    // with no link → NULL feed sort key). withUserDb wraps the txn in
    // retryOnTxnConflict (40P01/40001), and the pool-exhaustion retry wraps the
    // whole createLink at the saveLink layer, so a rolled-back txn releases its
    // connection before that backoff (no double-wrap, no pressure). Notes,
    // schedules, and notify run AFTER commit (below): they do network/AI work
    // and run notes in parallel — neither safe to hold the single-connection
    // transaction open across.
    const committed = await withUserDb(plot.db, userId, async (trx) => {
      // skipNotify=true: a single notifySyncDOs fires after the link (+ notes)
      // exist. opts.db=trx commits the thread on the transaction; `prepared`
      // was computed above, outside the txn.
      const tr = await createThread(plot, threadData, true, {
        db: trx,
        prepared,
      });
      let committedThreadId = tr.id as Uuid;
      const committedPriorityId = tr.priorityId;
      // Whether this saveLink produced a genuinely new thread. Reset to false if
      // the link turns out to belong to a pre-existing thread (race dedup
      // below), so forward-mute only runs for fresh arrivals — not replies.
      let isNewThread = tr.created;

      // Build link defaults (all fields for INSERT)
      const linkDefaults: Record<string, any> = {
        thread_id: committedThreadId,
        created_by: plot.twistInstanceId,
        // Credit the resolved external author (from createThread), not the
        // connector twist instance. Falls back to the twist when no author.
        author_id: tr.authorId,
        updated_by: plot.getUpdatedBy(),
        sync_depth: plot.syncDepth + 1,
        source_created_at:
          link.created instanceof Date
            ? link.created.toISOString()
            : typeof link.created === "string"
              ? link.created
              : new Date().toISOString(),
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
        ...(link.channelId !== undefined ? { channel_id: link.channelId } : {}),
        ...(link.relatedSource !== undefined
          ? { related_source: link.relatedSource }
          : {}),
        ...(hasSource ? { sources: sourcesArray } : {}),
        priority: link.priority ?? 0,
      };

      let linkId: string;

      if (hasSource) {
        // Build upsert fields (only explicitly provided values for UPDATE)
        const linkUpsert: Record<string, any> = {
          source: primarySource,
          sources: sourcesArray,
          thread_id: committedThreadId,
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
        if (link.priority !== undefined) linkUpsert.priority = link.priority;
        if (link.relatedSource !== undefined)
          linkUpsert.related_source = link.relatedSource;

        const linkResult = await rpcUser(trx, "upsert_link", {
          user_id: userId,
          p_link: linkUpsert as Json,
          p_defaults: linkDefaults as Json,
        });
        linkId = linkResult.id;

        // If the link was already associated with a different thread (race
        // where concurrent saveLink calls for the same source each create a
        // thread), clean up the orphan thread we just created and use the
        // existing one. On the transaction so the cleanup commits atomically.
        if (linkResult.thread_id && linkResult.thread_id !== committedThreadId) {
          // Archive (not delete) the orphan thread so the removal syncs to
          // clients; archived_at frees the (twist_id, key) slot just like
          // delete (thread_twist_key_unique is WHERE archived_at IS NULL).
          // The thread has no links (the link moved to linkResult.thread_id),
          // so there is no link cascade.
          await archiveOrDeleteOrphanThread(plot, committedThreadId, trx);
          committedThreadId = linkResult.thread_id as Uuid;
          // The link belonged to a pre-existing thread, not the one we created.
          isNewThread = false;
        }
      } else {
        // Plain insert for links without source
        const linkResult = await trx
          .insertInto("link")
          // @ts-ignore - Type mismatch between builder and actual values
          .values({
            thread_id: committedThreadId,
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
          })
          .returning("id")
          .executeTakeFirstOrThrow();
        linkId = linkResult.id;
      }

      return {
        threadId: committedThreadId,
        threadPriorityId: committedPriorityId,
        linkId,
        isNewThread,
      };
    },
    // Guarantee the 5s background-lane lock_timeout applies inside the txn even
    // when Hyperdrive hands back a reused backend that dropped the `-c` GUC (no
    // DB-level default for lock_timeout). Without this, upsert_thread waits the
    // full 30s statement_timeout on contention and one holder pileups 58×
    // (PostHog 019f1aec). 5000 matches createDb()'s background-lane intent.
    5000);

    const { threadId, threadPriorityId, linkId, isNewThread } = committed;

    // Boundary captured just before createNotes so the unread-marking below
    // scopes its "any other-authored note?" check to the notes created by THIS
    // saveLink (mirrors createThread's own syncStartedAt).
    const syncStartedAt = new Date();

    // Create notes against the resolved linkId so note.link_id is set on
    // the first write — keeps the FK valid and lets the partial unique
    // index (thread_id, link_id, key) deduplicate connector keys per link.
    if (link.notes && link.notes.length > 0) {
      await createNotes(
        plot,
        link.notes.map((note) => ({
          ...note,
          thread: { id: threadId as Uuid },
        })),
        {
          priority_id: threadPriorityId,
          created_by: plot.twistInstanceId,
          link_id: linkId,
        }
      );
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

    // Establish per-user unread state now that the link's notes exist.
    // createThread already ran its own unread-marking, but that fired before
    // these notes were created (connectors attach notes to the link, AFTER the
    // thread), so in "non-authors" mode it saw no notes and skipped — leaving
    // the thread with no thread_state row, which user.thread reports as read
    // (unread = false). The thread then renders in Done until the deferred
    // unread queue task fills the row in, flashing to Active. Re-running here
    // makes the thread unread synchronously, before the first sync push.
    //
    // Runs BEFORE applyMuteForNewThread so a matching mute can still override it
    // to read + inactive (Done). Honors link.unread: false → leave read; true →
    // unread for all; omitted → unread for non-authors. Best effort: the
    // deferred queue task is a fallback, so a failure here must never break
    // connector ingestion.
    if (link.unread !== false) {
      try {
        await markThreadUnreadForUsers(
          plot,
          threadId,
          link.unread === true ? "all" : "non-authors",
          syncStartedAt
        );
      } catch (unreadError) {
        const postHog = new PostHog(plot.env.POSTHOG_API_KEY, {
          host: plot.env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
        });
        postHog.captureException(
          unreadError as Error,
          await plot.getUserId().catch(() => undefined),
          {
            context: "plot:createLink:markThreadUnreadForUsers",
            twist_instance_id: plot.twistInstanceId,
            thread_id: threadId,
          },
        );
        await postHog.shutdown();
      }
    } else {
      // link.unread === false: the connector reports this thread is read (the
      // owner read it in the source app, or it's an initial-sync backfill item).
      // Clear the owner's LIVE unread now that the notes exist (so the read-vs-
      // content race guard sees the real latest-note time). createThread's own
      // unread===false branch only writes the legacy thread_read table, which
      // user.thread.unread ignores — so without this an already-unread thread
      // (e.g. one marked unread on a prior sync) never clears.
      try {
        await markThreadReadForOwner(plot, threadId);
      } catch (readError) {
        const postHog = new PostHog(plot.env.POSTHOG_API_KEY, {
          host: plot.env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
        });
        postHog.captureException(
          readError as Error,
          await plot.getUserId().catch(() => undefined),
          {
            context: "plot:createLink:markThreadReadForOwner",
            twist_instance_id: plot.twistInstanceId,
            thread_id: threadId,
          },
        );
        await postHog.shutdown();
      }
    }

    // Forward-mute: apply the owner's "Skip active for threads like this" rules
    // now that the link (channel_id + author_id) is attached, so recurring
    // connector threads (Gmail sign-in emails, Slack notifications, …) auto-skip
    // just like client-composed auto-filed threads. Only for genuinely new
    // threads — replies/updates on existing threads must not re-mute. Best
    // effort: a mute failure must never break connector ingestion.
    if (isNewThread) {
      try {
        await applyMuteForNewThread(plot.db, await plot.getUserId(), threadId);
      } catch (muteError) {
        const postHog = new PostHog(plot.env.POSTHOG_API_KEY, {
          host: plot.env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
        });
        postHog.captureException(
          muteError as Error,
          await plot.getUserId().catch(() => undefined),
          {
            context: "plot:applyMuteForNewThread",
            twist_instance_id: plot.twistInstanceId,
            thread_id: threadId,
          },
        );
        await postHog.shutdown();
      }
    }

    // Single notify after thread + link (+ schedules) are all written so the
    // first sync push the client receives already has the link row, and
    // activity_at computes from link.source_created_at instead of falling
    // back to thread.created_at = now().
    await plot.notifySyncDOs(new Set([threadPriorityId]));

    return threadId;
  } catch (error) {
    throw await handleDbOperationError(error, "createLink", plot, {
      has_notes: !!link.notes?.length,
      has_source: "source" in link && !!(link as any).source,
    });
  }
}

/**
 * Creates a link row without creating a thread.
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

    // Resolve assignee. Scope contact linking to the twist owner's root priority.
    const rootPriorityId = await plot.getRootPriorityId();
    let assigneeId: string | null | undefined = undefined;
    if (link.assignee !== undefined) {
      assigneeId = await processNewActor(
        plot,
        link.assignee,
        rootPriorityId
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

    // Resolve the link's external author directly (no createThread here to do
    // it for us). Falls back to the twist instance when no author is supplied.
    const linkAuthorId = link.author
      ? ((await processNewActor(plot, link.author, rootPriorityId)) ??
          plot.twistInstanceId)
      : plot.twistInstanceId;

    const linkValues: Record<string, any> = {
      thread_id: null,
      priority_id: rootPriorityId,
      created_by: plot.twistInstanceId,
      author_id: linkAuthorId,
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      source_created_at:
        link.created instanceof Date
          ? link.created.toISOString()
          : typeof link.created === "string"
            ? link.created
            : new Date().toISOString(),
      title: link.title,
      preview: previewText,
      assignee_id: assigneeId ?? null,
      type: link.type ?? null,
      status: link.status ?? null,
      actions: (link.actions ?? null) as Json | null,
      meta: (link.meta ?? null) as Json | null,
      source_url: link.sourceUrl ?? null,
      channel_id: link.channelId ?? null,
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
    throw await handleDbOperationError(error, "createLinkOnly", plot, {
      has_source: "source" in link && !!(link as any).source,
    });
  }
}

/**
 * Queries links from connected channels for this twist.
 * Returns links with their associated notes.
 */
export async function getLinks(
  plot: Plot,
  filter?: LinkFilter
): Promise<Array<{ link: Link; notes: Note[] }>> {
  // Get connected channel info
  let query = plot.db
    .selectFrom("twist_instance_channel")
    .innerJoin("link", (join) =>
      join
        .onRef("link.created_by", "=", "twist_instance_channel.source_twist_instance_id")
        .onRef("link.channel_id", "=", "twist_instance_channel.channel_id")
    )
    .leftJoin("actor as author", "author.id", "link.author_id")
    .leftJoin("actor as assignee", "assignee.id", "link.assignee_id")
    .select([
      "link.id",
      "link.thread_id",
      "link.source",
      "link.sources",
      "link.priority",
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
    .where("twist_instance_channel.twist_instance_id", "=", plot.twistInstanceId)
    .where("twist_instance_channel.enabled", "=", true)
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
            "note.access_contacts",
            "note.archived_at",
            "note.actions",
            "actor.name as author_name",
            "actor.type as author_type",
          ])
          .select([
            sql<string | null>`note.section_key`.as("section_key"),
            sql<string | null>`note.section_label`.as("section_label"),
            sql<string | null>`note.section_position`.as("section_position"),
            sql<string | null>`note.item_position`.as("item_position"),
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
                : row.author_type === "twist_instance"
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
                : row.assignee_type === "twist_instance"
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
      sources: row.sources ?? [],
      priority: row.priority ?? 0,
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
            : n.author_type === "twist_instance"
            ? ActorType.Twist
            : ActorType.Contact,
      },
      content: n.content,
      key: n.key || null,
      reNote: n.re_note_id ? { id: n.re_note_id as Uuid } : null,
      mentions: (n.mentions as ActorId[]) || [],
      tags: {},
      reactions: {},
      accessContacts: (n.access_contacts as ActorId[]) ?? null,
      archived: n.archived_at !== null,
      actions: n.actions as any,
      cta: null,
      sectionKey: n.section_key ?? null,
      sectionLabel: n.section_label ?? null,
      sectionPosition: n.section_position ?? null,
      itemPosition: n.item_position ?? null,
      tagActors: {},
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
    const userId = await plot.getUserId();
    const currentThreadPriority = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", existingLink.thread_id)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    if (currentThreadPriority?.priority_id) {
      await plot.validatePriorityAccess(currentThreadPriority.priority_id);
    }
  }

  if (link.threadId !== undefined) {
    // Verify target thread exists and is within scope
    const userId = await plot.getUserId();
    const targetThread = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", link.threadId)
      .where("user_id", "=", userId)
      .executeTakeFirst();

    if (!targetThread) {
      throw new Error(`Target thread not found: ${link.threadId}`);
    }
    // Pending case-A rows (priority_id NULL) skip the access check.
    // The consumer Worker will fill priority_id shortly; meanwhile the
    // link still attaches to the user's pending thread row.
    if (targetThread.priority_id) {
      await plot.validatePriorityAccess(targetThread.priority_id);
    }

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
