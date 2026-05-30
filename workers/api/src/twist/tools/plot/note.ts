import type { Database } from "@plotday/db";
import { sql } from "kysely";
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
import { PostHog } from "posthog-node";

import { detectTasks } from "../../../queue/note-analysis";
import { rpc } from "../../../rpc";
import { checkAiLimit, recordAiUsage } from "../../../utils/ai-limits";
import { hashExternalContent } from "../hash-external-content";
import { getLinkTypesForLink } from "../../../app/sync/link-tags";
import { resolveAccessContactsForSend, type SharingModel } from "../../../app/sync/notes";
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
  /**
   * The link this note batch belongs to. Set by createLink to scope
   * note.key uniqueness to (thread_id, link_id, key). Omitted for
   * user-authored or Plot-tool batches that aren't tied to a link.
   */
  link_id?: string;
};

/**
 * Resolves which link a connector-authored note belongs to when the caller
 * didn't pass it explicitly (e.g. bare saveNote on an existing thread).
 *
 * Rules:
 *   - Exactly one link by this connector instance on this thread → use it.
 *   - Multiple → throw. Connectors should call saveLink (which carries the
 *     link explicitly) instead of bare saveNote on merged threads.
 *   - Zero → return null. The note will be inserted with link_id = NULL
 *     and coexist with other NULL-link notes via the partial unique index's
 *     NULL semantics. Happens when the link was deleted but the note kept,
 *     or when this code path is invoked before any link exists.
 */
export async function resolveLinkIdForConnectorNote(
  db: Plot["db"],
  threadId: string,
  twistInstanceId: string
): Promise<string | null> {
  const links = await db
    .selectFrom("link")
    .select("id")
    .where("thread_id", "=", threadId)
    .where("created_by", "=", twistInstanceId)
    .execute();

  if (links.length === 0) return null;
  if (links.length === 1) return links[0].id;
  throw new Error(
    `Cannot resolve link for keyed note: thread ${threadId} has ${links.length} links from this connector. Use saveLink instead, or specify the link explicitly.`
  );
}

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
      // Look up activity by source and priority root via the link table.
      // Match either the legacy `source` column or any element of `sources`,
      // so a connector can attach a note to a calendar event by any of its
      // canonical aliases (e.g. `icaluid:<UID>`).
      const sourceValue = note.thread.source;
      const priorityRoot = await plot.getPriorityRoot();
      const existingLink = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source_priority_root", "=", priorityRoot)
        .where(
          sql<boolean>`(link.source = ${sourceValue} OR link.sources @> ARRAY[${sourceValue}]::text[])`
        )
        .executeTakeFirst();

      if (!existingLink || !existingLink.thread_id) {
        throw new Error(
          `Activity not found with source "${sourceValue}": Not found`
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
    let threadContacts: string[] = [];
    if (activityContext) {
      priorityId = activityContext.priority_id;
      if (activityContext.created_by) {
        threadCreatedBy = activityContext.created_by;
        // Fetch contacts in the same trip as the created_by check
        const contactsRow = await plot.db
          .selectFrom("thread")
          .select("contacts")
          .where("id", "=", activityId)
          .executeTakeFirst();
        threadContacts = contactsRow?.contacts ?? [];
      } else {
        // Fallback: fetch created_by and contacts together
        const threadRow = await plot.db
          .selectFrom("thread")
          .select(["created_by", "contacts"])
          .where("id", "=", activityId)
          .executeTakeFirst();
        threadCreatedBy = threadRow?.created_by ?? null;
        threadContacts = threadRow?.contacts ?? [];
      }
    } else {
      const activityData = await plot.db
        .selectFrom("thread")
        .select(["created_by", "contacts"])
        .where("id", "=", activityId)
        .executeTakeFirst();

      if (!activityData) {
        throw new Error(`Activity not found: ${activityId}`);
      }

      const userId = await plot.getUserId();
      const tp = await plot.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", activityId)
        .where("user_id", "=", userId)
        .executeTakeFirst();

      priorityId = tp?.priority_id ?? "";
      threadCreatedBy = activityData.created_by;
      threadContacts = activityData.contacts ?? [];
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

    // For keyed (connector-synced) notes with content, compute the external
    // sync baseline. The hash covers the content as the connector provided
    // it — pre-markdown conversion — so a connector's subsequent sync of
    // unchanged external content produces the same hash and the upsert
    // preserves Plot's (possibly richer) content. When the external side
    // is actually edited, the hash diverges and we fall through to the
    // overwrite path. See preservation logic on the ON CONFLICT below.
    let externalContentHash: string | null = null;
    const noteKey = "key" in note && typeof note.key === "string" ? note.key : null;
    if (noteKey && note.content) {
      externalContentHash = await hashExternalContent(note.content);
    }

    // Process author - use provided author or default to twist
    const authorId = note.author
      ? await processNewActor(plot, note.author, priorityId)
      : plot.twistInstanceId;

    // Process mentions if provided - convert NewActor[] to ActorId[]
    let mentionIds: ActorId[] | null = null;
    if (note.mentions) {
      mentionIds = await processNewActorArray(plot, note.mentions, priorityId);
    }

    // Auto-mention the calling twist so it stays routed for future notes
    if (mentionIds === null) mentionIds = [];
    if (!mentionIds.includes(plot.twistInstanceId as ActorId)) {
      mentionIds.push(plot.twistInstanceId as ActorId);
    }

    // Auto-mention the thread-creating twist (if different from calling twist)
    // so the thread creator continues to receive notes
    if (threadCreatedBy && threadCreatedBy !== plot.twistInstanceId) {
      const isCreatorTwist = await plot.db
        .selectFrom("twist_instance")
        .select("id")
        .where("id", "=", threadCreatedBy)
        .executeTakeFirst();
      if (isCreatorTwist && !mentionIds.includes(threadCreatedBy as ActorId)) {
        mentionIds.push(threadCreatedBy as ActorId);
      }
    }

    // Resolve accessContacts: may contain NewContact objects (email-based) or raw ActorIds
    let resolvedAccessContacts: string[] | null = null;
    if (note.accessContacts && note.accessContacts.length > 0) {
      const hasNewContacts = note.accessContacts.some(
        (ac: any) => typeof ac === "object" && "email" in ac
      );
      if (hasNewContacts) {
        resolvedAccessContacts = await processNewActorArray(
          plot,
          note.accessContacts as any[],
          priorityId
        );
      } else {
        resolvedAccessContacts = note.accessContacts as string[];
      }
    } else if (note.accessContacts === null) {
      resolvedAccessContacts = null;
    }

    // Convert Note to database format
    const dbNote: any = {
      author_id: authorId,
      created_by: plot.twistInstanceId,
      thread_id: activityId,
      source_created_at:
        note.created instanceof Date
          ? note.created.toISOString()
          : typeof note.created === "string"
            ? note.created
            : new Date().toISOString(),
      draft: false,
      access_contacts: resolvedAccessContacts,
      content: contentToStore,
      external_content_hash: externalContentHash,
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

    // Set link_id from explicit context first (saveLink path). For bare
    // saveNote calls from a connector (or other twist), resolve by querying
    // the thread's links for this connector instance. Only resolve keyed
    // notes — unkeyed notes can't collide on the partial unique index.
    // User-authored notes have no twistInstanceId and leave link_id NULL.
    if (activityContext?.link_id) {
      dbNote.link_id = activityContext.link_id;
    } else if (plot.twistInstanceId && dbNote.key) {
      dbNote.link_id = await resolveLinkIdForConnectorNote(
        plot.db,
        activityId,
        plot.twistInstanceId
      );
    }

    // Resolve link metadata used for both access_contacts enforcement and
    // canonical_source dedup. A single query covers both needs.
    let resolvedLinkMeta: { type: string | null; created_by: string | null; source: string | null } | null = null;
    if (dbNote.link_id) {
      resolvedLinkMeta = await plot.db
        .selectFrom("link")
        .select(["type", "created_by", "source"])
        .where("id", "=", dbNote.link_id)
        .executeTakeFirst() ?? null;
    }

    // Enforce the always-explicit access_contacts invariant for message-mode
    // threads. For non-message modes this is a no-op (resolver returns the
    // value unchanged). For message mode, NULL access_contacts is replaced
    // with the thread's current contacts array so downstream per-viewer
    // participant derivation (T9+) always has an explicit participant list.
    if (resolvedLinkMeta) {
      // Only resolve the sharing model when link.created_by is set.
      // If it is null (data anomaly), skip resolution; sharingModel stays "thread".
      let sharingModel: SharingModel = "thread";
      if (resolvedLinkMeta.created_by) {
        const linkTypes = await getLinkTypesForLink(
          plot.db,
          dbNote.link_id,
          resolvedLinkMeta.created_by
        );
        const linkTypeConfig = resolvedLinkMeta.type
          ? linkTypes.find((lt) => lt.type === resolvedLinkMeta!.type)
          : undefined;
        if (linkTypeConfig?.sharingModel) sharingModel = linkTypeConfig.sharingModel;
      }
      dbNote.access_contacts = resolveAccessContactsForSend({
        bodyAccessContacts: dbNote.access_contacts,
        sharingModel,
        threadContacts,
      });
    }

    // Resolve canonical_source for cross-connection dedup. When two users'
    // connections of the same external resource each write a note with the
    // same key, both links have the same `link.source` (the connector
    // canonical identifier, e.g. `google-calendar:<iCalUID>`). Copying that
    // onto the note lets the partial unique index on
    // (thread_id, canonical_source, key) collapse the writes to one row.
    if (dbNote.link_id && dbNote.key) {
      if (resolvedLinkMeta?.source) {
        dbNote.canonical_source = resolvedLinkMeta.source;
      }
    }

    // Serialize all keyed writers on (thread_id, key). The lock is wider than
    // either partial unique index so concurrent writers with mismatched
    // canonical_source values (e.g. legacy NULL vs. a freshly populated source)
    // still serialize. A narrower lock keyed on canonical_source let writers
    // with different canonical_source values race and hit the per-link index
    // as a hard duplicate. Precedent: update_thread_on_note_change in
    // libs/db/schema/50-tables/25-note.sql takes a per-thread advisory lock.
    if (dbNote.key) {
      await sql`SELECT pg_advisory_xact_lock(hashtext(${
        `${dbNote.thread_id}:${dbNote.key}`
      }))`.execute(plot.db);
    }

    // Pre-resolve cross-index conflicts before the upsert. The note table has
    // two partial unique indexes — (thread_id, link_id, key) and
    // (thread_id, canonical_source, key). The upsert below targets only one
    // of them. If an existing per-link row has a NULL or different
    // canonical_source from what we're about to insert, the canonical_source
    // ON CONFLICT target doesn't match it but the per-link index still fires
    // as a hard duplicate. Backfill canonical_source on the per-link row so
    // the upsert merges via the canonical_source target, or archive it if a
    // separate cross-user row already holds the canonical_source.
    if (dbNote.canonical_source && dbNote.link_id && dbNote.key) {
      const existingByLink = await plot.db
        .selectFrom("note")
        .select(["id", "canonical_source"])
        .where("thread_id", "=", dbNote.thread_id)
        .where("link_id", "=", dbNote.link_id)
        .where("key", "=", dbNote.key)
        .executeTakeFirst();

      if (
        existingByLink &&
        existingByLink.canonical_source !== dbNote.canonical_source
      ) {
        const existingByCanonical = await plot.db
          .selectFrom("note")
          .select(["id"])
          .where("thread_id", "=", dbNote.thread_id)
          .where("canonical_source", "=", dbNote.canonical_source)
          .where("key", "=", dbNote.key)
          .executeTakeFirst();

        if (existingByCanonical && existingByCanonical.id !== existingByLink.id) {
          // Cross-user row already holds canonical_source; converge by
          // archiving the per-link row.
          await plot.db
            .updateTable("note")
            .set({
              archived_at: new Date().toISOString(),
              updated_by: plot.getUpdatedBy(),
              sync_depth: plot.syncDepth + 1,
            })
            .where("id", "=", existingByLink.id)
            .execute();
        } else {
          // No cross-user row; backfill canonical_source on the per-link row
          // so the upcoming upsert merges via the canonical_source target.
          await plot.db
            .updateTable("note")
            .set({
              canonical_source: dbNote.canonical_source,
              updated_by: plot.getUpdatedBy(),
              sync_depth: plot.syncDepth + 1,
            })
            .where("id", "=", existingByLink.id)
            .execute();
        }
      }
    }

    // Insert or upsert note based on whether key is provided.
    // When key is provided, use upsert to handle duplicate keys within same activity.
    //
    // Two ON CONFLICT targets:
    //   - When canonical_source is set: dedup across links sharing the same
    //     external resource (one live note per (thread, canonical_source, key)).
    //     The arbiter index is partial on `archived_at IS NULL`, so the WHERE
    //     below must include it to match. `link_id` is omitted from the update
    //     so the first writer's link attribution stays pinned.
    //   - Otherwise: fall back to the per-link key index (one note per
    //     (thread, link_id, key)).
    //
    // Sync-baseline preservation: `note.external_content_hash` records the
    // hash of the last external-provided content the runtime saw for this
    // note. On re-upsert with the same hash, the external side is unchanged,
    // so we preserve the existing `content` (which may be a richer Plot-side
    // version — e.g. Plot-authored markdown round-tripping through a plain-
    // text-only comments API, or a user-edited note whose new content Plot
    // has but the connector hasn't pushed yet). When the hash differs, the
    // external side was edited and we overwrite. When either hash is NULL,
    // we fall back to the prior "overwrite always" behavior.
    //
    // The WHERE clause also gates on hash equality so a "same content"
    // re-sync doesn't fire UPDATE and wake the sync_twist_for_note trigger
    // (which would create a feedback loop).
    const onConflictUpdateSet = (eb: any) => ({
      author_id: eb.ref("excluded.author_id"),
      created_by: eb.ref("excluded.created_by"),
      source_created_at: eb.ref("excluded.source_created_at"),
      draft: eb.ref("excluded.draft"),
      access_contacts: eb.ref("excluded.access_contacts"),
      content: sql<string | null>`CASE
        WHEN excluded.external_content_hash IS NOT NULL
          AND note.external_content_hash IS NOT NULL
          AND excluded.external_content_hash = note.external_content_hash
        THEN note.content
        ELSE excluded.content
      END` as any,
      external_content_hash: sql<string | null>`COALESCE(excluded.external_content_hash, note.external_content_hash)` as any,
      actions: eb.ref("excluded.actions"),
      mentions: eb.ref("excluded.mentions"),
      updated_by: eb.ref("excluded.updated_by"),
      sync_depth: eb.ref("excluded.sync_depth"),
      archived_at: eb.ref("excluded.archived_at"),
      re_note_id: eb.ref("excluded.re_note_id"),
      canonical_source: eb.ref("excluded.canonical_source"),
    });

    const onConflictWhere = (eb: any) =>
      eb.or([
        // Content-distinct check only matters when we lack a
        // baseline on either side; otherwise the hash comparison
        // is the authoritative "did external change" signal.
        eb.and([
          eb.or([
            eb("excluded.external_content_hash", "is", null),
            eb("note.external_content_hash", "is", null),
          ]),
          eb("note.content", "is distinct from", eb.ref("excluded.content")),
        ]),
        eb("note.external_content_hash", "is distinct from", eb.ref("excluded.external_content_hash")),
        eb("note.author_id", "is distinct from", eb.ref("excluded.author_id")),
        eb("note.source_created_at", "is distinct from", eb.ref("excluded.source_created_at")),
        eb("note.archived_at", "is distinct from", eb.ref("excluded.archived_at")),
        eb("note.re_note_id", "is distinct from", eb.ref("excluded.re_note_id")),
        eb("note.mentions", "is distinct from", eb.ref("excluded.mentions")),
        eb("note.actions", "is distinct from", eb.ref("excluded.actions")),
        eb("note.draft", "is distinct from", eb.ref("excluded.draft")),
        eb("note.access_contacts", "is distinct from", eb.ref("excluded.access_contacts")),
      ]);

    let dbResult = dbNote.key
      ? await plot.db
          .insertInto("note")
          .values(dbNote)
          .onConflict((oc) =>
            dbNote.canonical_source
              ? oc
                  .columns(["thread_id", "canonical_source", "key"])
                  .where("canonical_source", "is not", null)
                  .where("key", "is not", null)
                  .where("archived_at", "is", null)
                  .doUpdateSet(onConflictUpdateSet)
                  .where(onConflictWhere)
              : oc
                  .columns(["thread_id", "link_id", "key"])
                  .where("key", "is not", null)
                  .doUpdateSet(onConflictUpdateSet)
                  .where(onConflictWhere)
          )
          .returningAll()
          .executeTakeFirst() ?? null
      : await plot.db
          .insertInto("note")
          .values(dbNote)
          .returningAll()
          .executeTakeFirstOrThrow();

    // If upsert was a no-op (existing row with identical content), fetch the existing row.
    // Match whichever partial unique index applies — link_id may be NULL.
    if (!dbResult) {
      let q = plot.db
        .selectFrom("note")
        .selectAll()
        .where("thread_id", "=", dbNote.thread_id)
        .where("key", "=", dbNote.key);
      if (dbNote.canonical_source) {
        q = q.where("canonical_source", "=", dbNote.canonical_source);
      } else if (dbNote.link_id) {
        q = q.where("link_id", "=", dbNote.link_id);
      } else {
        q = q.where("link_id", "is", null);
      }
      dbResult = await q.executeTakeFirstOrThrow();
    }

    // Generate embedding (best-effort, don't fail the create)
    if (
      contentToStore &&
      contentToStore.trim().length > 0 &&
      (await plot.isAiEnabled())
    ) {
      const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
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
            twist_instance_id: plot.twistInstanceId,
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

    // Add reactions if provided. Parallel to tags above but keyed by
    // emoji string (Unicode grapheme or `provider:workspace/name` ref).
    if (note.reactions) {
      const reactionInserts: Array<{
        note_id: string;
        emoji: string;
        actor_id: string;
        updated_by: number;
        sync_depth: number;
      }> = [];
      for (const [emoji, newActors] of Object.entries(note.reactions)) {
        if (!newActors || newActors.length === 0) continue;
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          priorityId
        );
        for (const actorId of actorIds) {
          reactionInserts.push({
            note_id: dbResult.id,
            emoji,
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          });
        }
      }
      if (reactionInserts.length > 0) {
        await plot.db
          .insertInto("note_reaction")
          .values(reactionInserts)
          .onConflict((oc) =>
            oc
              .columns(["actor_id", "note_id", "emoji"])
              .doUpdateSet((eb) => ({
                archived_at: null,
                updated_by: eb.ref("excluded.updated_by"),
                sync_depth: eb.ref("excluded.sync_depth"),
              }))
          )
          .execute();
      }
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    if (!skipNotify) {
      await plot.notifySyncDOs(new Set([priorityId]));
    }

    // Return just the ID for efficiency
    return dbResult.id as Uuid;
  } catch (error) {
    handleDbOperationError(error, "createNote", plot.twistInstanceId, {
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

  // Inline task detection for notes with checkForTasks flag
  const checkForTasksNotes = processedNotes
    .map((note, index) => ({ note, index }))
    .filter(
      ({ note, index }) =>
        note.checkForTasks === true &&
        results[index].status === "fulfilled"
    );

  if (checkForTasksNotes.length > 0 && activityContext) {
    // Resolve owner for AI limit check
    const ownerRow = await plot.db
      .selectFrom("twist_instance")
      .select("owner_id")
      .where("id", "=", plot.twistInstanceId)
      .executeTakeFirst();
    const ownerId = ownerRow?.owner_id;

    if (ownerId) {
      const aiAllowed = await checkAiLimit(plot.env, plot.db, ownerId, "note_processing");
      if (aiAllowed.allowed) {
        for (const { note, index } of checkForTasksNotes) {
          const noteId = (results[index] as PromiseFulfilledResult<Uuid>).value;
          // Only detect tasks on recent notes (< 7 days old)
          const sourceCreatedAt = note.created
            ? new Date(note.created instanceof Date ? note.created.getTime() : note.created).getTime()
            : Date.now();
          const isRecent = Date.now() - sourceCreatedAt < 7 * 24 * 60 * 60 * 1000;
          if (!isRecent) continue;

          // Resolve thread ID from the note
          const threadId = "id" in note.thread ? note.thread.id : undefined;
          if (!threadId) continue;

          try {
            await detectTasks(
              plot.env,
              noteId,
              threadId,
              ownerId,
              plot.twistInstanceId
            );
          } catch (error) {
            const logger = createLogger({ component: "plot_tool" });
            logger.error("Failed to detect tasks for note", error as Error, {
              note_id: noteId,
            });
            const postHog = new PostHog(plot.env.POSTHOG_API_KEY, { host: plot.env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
            postHog.captureException(error as Error, ownerId, { context: "detect-tasks:createNotes", note_id: noteId });
            await postHog.shutdown();
          }
        }
        recordAiUsage(plot.env, ownerId, "note_processing");
      }
    }
  }

  // Notify sync DOs once for the batch (unless called from createActivities which notifies itself)
  if (!activityContext) {
    const rootPriorityId = await plot.getRootPriorityId();
    await plot.notifySyncDOs(new Set([rootPriorityId]));
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
      // Look up note by key. For connector callers, scope to the connector's
      // links on this thread so we don't match another connector's note with
      // the same key (e.g. "description") after a merge. NoteUpdate doesn't
      // carry thread_id, so we have to accept a cross-thread risk for
      // non-connector callers — same as before. With the new partial unique
      // index (thread_id, link_id, key) WHERE key IS NOT NULL, two notes
      // can share the same key on the same thread when they belong to
      // different links, so the unscoped lookup may return the wrong row.
      const twistInstanceId = plot.twistInstanceId;
      const existingNote = await plot.db
        .selectFrom("note")
        .select(["note.id"])
        .where("note.key", "=", note.key)
        .$if(twistInstanceId != null, (qb) =>
          qb
            .innerJoin("link", "link.id", "note.link_id")
            .where("link.created_by", "=", twistInstanceId!)
        )
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

    // Enforce per-twist permission level on the parent thread. A twist
    // holding only ThreadAccess.Respond (or installed with requireApproval)
    // must not be able to update notes on arbitrary threads it merely
    // observed; the validator checks created_by / mentions / approval-gate
    // for the parent activity, same as the create path does.
    await plot.validateActivityUpdateAccess(noteData.thread_id);

    // Validate access to the activity's priority
    const noteUserId = await plot.getUserId();
    const activityPriority = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", noteData.thread_id)
      .where("user_id", "=", noteUserId)
      .executeTakeFirst();

    if (!activityPriority) {
      throw new Error(`Activity not found: ${noteData.thread_id}`);
    }

    // Pending case-A rows have priority_id NULL — fall back to the
    // user's root priority so downstream tag/actor processing works.
    let priorityId = activityPriority.priority_id;
    if (priorityId == null) {
      const root = await plot.db
        .selectFrom("priority")
        .select("id")
        .where("user_id", "=", noteUserId)
        .where(sql<number>`nlevel(path)`, "=", 1)
        .where("archived_at", "is", null)
        .orderBy("created_at", "asc")
        .executeTakeFirstOrThrow();
      priorityId = root.id;
    }

    // Skip priority access validation for notes - activities may have been moved
    // after creation and the twist should still be able to update notes

    // Build update object (cast needed because @plotday/db types halfvec as
    // unknown; same applies to seq which is xid8 — never set by callers, the
    // BEFORE UPDATE trigger maintains it).
    const dbUpdate: Omit<
      Database["public"]["Tables"]["note"]["Update"],
      "embedding" | "seq"
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
    if (note.accessContacts !== undefined) {
      dbUpdate.access_contacts = note.accessContacts;
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
      const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
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

    // Handle reactions if provided. Mirrors the tag block above: passing
    // `reactions` declares the full reaction state, so clear and replace.
    // Connectors syncing platform reactions must pass the complete
    // current reactor set per emoji.
    if (note.reactions !== undefined) {
      await plot.db
        .deleteFrom("note_reaction")
        .where("note_id", "=", noteId)
        .execute();

      const reactionInserts: Array<{
        note_id: string;
        emoji: string;
        actor_id: string;
        updated_by: number;
        sync_depth: number;
      }> = [];
      for (const [emoji, newActors] of Object.entries(note.reactions)) {
        if (!newActors || newActors.length === 0) continue;
        const actorIds = await processNewActorArray(
          plot,
          newActors,
          priorityId
        );
        for (const actorId of actorIds) {
          reactionInserts.push({
            note_id: noteId,
            emoji,
            actor_id: actorId,
            updated_by: plot.getUpdatedBy(),
            sync_depth: plot.syncDepth + 1,
          });
        }
      }
      if (reactionInserts.length > 0) {
        await plot.db
          .insertInto("note_reaction")
          .values(reactionInserts)
          .execute();
      }
    }

    // Notify sync DOs since triggers skip HTTP calls for twist writes
    await plot.notifySyncDOs(new Set([priorityId]));
  } catch (error) {
    handleDbOperationError(error, "updateNote", plot.twistInstanceId, {
      has_note_id: "id" in note && !!note.id,
      has_key: "key" in note && !!note.key,
      update_fields: Object.keys(note).filter((k) => k !== "id" && k !== "key"),
    });
  }
}

export async function getNotes(plot: Plot, activity: Thread): Promise<Note[]> {
  try {
    // Validate access to the priority
    await plot.validatePriorityAccess(activity.focus.id);

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
        "access_contacts",
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
        accessContacts: (row.access_contacts as ActorId[]) ?? null,
        archived: row.archived_at !== null,
        content: row.content,
        key: row.key || null,
        reNote: row.re_note_id ? { id: row.re_note_id as Uuid } : null,
        actions: row.actions as Action[] | null,
        mentions: (row.mentions as string[])?.map((m) => m as ActorId) ?? [],
        tags:
          (tagsMap.get(row.id) as Partial<Record<Tag, ActorId[]>> | null) || {},
        reactions: {},
      };
    });
  } catch (err) {
    const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
    logger.error("Failed to get notes", err as Error);
    throw err;
  }
}
