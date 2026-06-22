import { Hono } from "hono";
import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { type DB, type Kysely, createFrontendDb, sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { analyzeNote } from "../../queue/note-analysis";
import { rpcUser } from "../../rpc";
import {
  checkAiLimitForContacts,
  isAiEnabled,
  recordAiUsage,
} from "../../utils/ai-limits";
import { assertThreadAccess } from "./authorize";
import { getLinkTypesForLink, type SharingModel } from "./link-tags";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { getPriorityForThread, notifySync } from "./notify";

export type { SharingModel };

export function resolveAccessContactsForSend(args: {
  bodyAccessContacts: string[] | null | undefined;
  sharingModel: SharingModel;
  threadContacts: string[];
}): string[] | null {
  const { bodyAccessContacts, sharingModel, threadContacts } = args;
  if (sharingModel !== "message") {
    return Array.isArray(bodyAccessContacts) ? bodyAccessContacts : null;
  }
  // Message-mode invariant: never store NULL access_contacts.
  if (Array.isArray(bodyAccessContacts)) return bodyAccessContacts;
  return [...threadContacts];
}

export function resolveAccessGroupsForSend(args: {
  bodyAccessGroups: unknown;
}): string[] | null {
  // Groups don't have a message-mode invariant (Gmail threads typically have
  // no Plot groups), so this is a straight pass-through with type coercion.
  const { bodyAccessGroups } = args;
  return Array.isArray(bodyAccessGroups) ? bodyAccessGroups : null;
}

const notes = new Hono<{ Bindings: Bindings }>();

// GET /sync/notes
notes.get("/sync/notes", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    threadId,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  // On initial sync (epoch or no updated_since/seq_since), a fresh client has
  // nothing to reconcile, so we skip the expensive redacted-stub query
  // entirely. On incremental sync, updated_since/seq_since narrows the
  // redacted branch so it's cheap.
  const isInitialSync = useSeqCursor
    ? seqSince === "0"
    : !updatedSince || updatedSince === "1970-01-01T00:00:00.000Z";

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    // Sort on the raw updated_at column so the planner can use
    // idx_note_updated_at. date_trunc() is still applied in the cursor
    // WHERE comparison to match JS Date millisecond precision.
    let visibleQ = trx
      .selectFrom("user.note")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);
    if (useSeqCursor) {
      visibleQ = visibleQ.orderBy("seq", "asc").orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      visibleQ = visibleQ.orderBy("updated_at", "asc").orderBy("id", "asc");
      visibleQ = visibleQ.where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      visibleQ = visibleQ.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }
    if (archived === true) visibleQ = visibleQ.where("archived_at", "is not", null);
    else if (archived === false) visibleQ = visibleQ.where("archived_at", "is", null);
    if (id) visibleQ = visibleQ.where("id", "=", id);
    if (threadId) visibleQ = visibleQ.where("thread_id", "=", threadId);

    // Bounded initial sync: on a fresh device (seq cursor at 0) with no
    // thread/id scope, restrict to notes whose thread is unread or active —
    // mirroring the /sync/threads initial filter. Without this, the global
    // note pull backfills the user's ENTIRE note history. Historical threads'
    // notes load on demand via the thread_id-scoped pull. The next_horizon in
    // the envelope still seeds the cursor to "now", so incremental pulls
    // (initial=false / seq>0) stay unfiltered and catch all deltas. Skipped
    // for archived pulls and per-thread / id fetches (those intentionally
    // reach historical threads).
    if (useSeqCursor && isInitialSync && !threadId && !id && archived !== true) {
      visibleQ = visibleQ.where(
        sql<boolean>`thread_id IN (
          SELECT id FROM "user".thread
          WHERE user_id = ${userId}::uuid
            AND archived_at IS NULL
            AND draft = false
            AND (unread = true OR active = true)
        )`
      );
    }

    const visible = await visibleQ.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    if (isInitialSync) return { rows: visible, horizon: horizonValue };

    let redactedQ = trx
      .selectFrom("user.note_redacted")
      .selectAll()
      .where("user_id", "=", userId)
      .limit(limit);
    if (useSeqCursor) {
      redactedQ = redactedQ.orderBy("seq", "asc").orderBy("id", "asc")
        .where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      redactedQ = redactedQ.orderBy("updated_at", "asc").orderBy("id", "asc");
      redactedQ = redactedQ.where(updatedSinceCursor(updatedSince, cursorId));
    } else {
      redactedQ = redactedQ.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }
    if (archived === true) redactedQ = redactedQ.where("archived_at", "is not", null);
    else if (archived === false) redactedQ = redactedQ.where("archived_at", "is", null);
    if (id) redactedQ = redactedQ.where("id", "=", id);
    if (threadId) redactedQ = redactedQ.where("thread_id", "=", threadId);

    const redacted = await redactedQ.execute();
    // Merge and re-sort across both sets, then slice to the requested limit.
    // Each server-side query is already bounded by `limit`; the redacted set
    // is typically tiny. seq sort takes precedence when seq cursor is in use.
    const merged = [...visible, ...redacted];
    if (useSeqCursor) {
      merged.sort((a, b) => {
        const as = (a as any).seq ?? "0";
        const bs = (b as any).seq ?? "0";
        if (as !== bs) return as < bs ? -1 : 1;
        const aid = a.id ?? "";
        const bid = b.id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    } else {
      merged.sort((a, b) => {
        const au = a.updated_at ? a.updated_at.getTime() : 0;
        const bu = b.updated_at ? b.updated_at.getTime() : 0;
        if (au !== bu) return au - bu;
        const aid = a.id ?? "";
        const bid = b.id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    }
    return { rows: merged.slice(0, limit), horizon: horizonValue };
  });

  // Enrich thread actions with current title and priorityId
  const threadIds = new Set<string>();
  for (const row of rows) {
    if (Array.isArray((row as any).actions)) {
      for (const action of (row as any).actions) {
        if (action.type === "thread" && action.threadId) {
          threadIds.add(action.threadId);
        }
      }
    }
  }

  if (threadIds.size > 0) {
    const threads = await withUserDb(c.var.db, userId, async (trx) =>
      trx
        .selectFrom("user.thread")
        .select(["id", "title", "priority_id"])
        .where("user_id", "=", userId)
        .where("id", "in", [...threadIds])
        .execute()
    );
    const threadMap = new Map(threads.map((t) => [t.id, t]));

    for (const row of rows) {
      if (Array.isArray((row as any).actions)) {
        for (const action of (row as any).actions) {
          if (action.type === "thread" && action.threadId) {
            const thread = threadMap.get(action.threadId);
            if (thread) {
              action.title = thread.title || "Untitled";
              action.priorityId = thread.priority_id;
            }
          }
        }
      }
    }
  }

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/notes - Upsert into note table
notes.post("/sync/notes", async (c) => {
  const body = await c.req.json();

  // Check if this is an update (note already exists) before upserting.
  // We only run AI analysis on new notes — re-analyzing on edits causes
  // the AI to re-apply tags that users intentionally removed.
  const isUpdate = body.id
    ? !!(await c.var.db
        .selectFrom("note")
        .select("id")
        .where("id", "=", body.id)
        .executeTakeFirst())
    : false;

  // Snapshot the RESOLVED note access (what's actually passed to upsert_note)
  // out of the withUserDb callback so the background waitUntil closure can read
  // it. Scoped-ness MUST be derived from these resolved values (not raw
  // body.access_*) so the API and the DB trigger agree on "scoped" — e.g. a
  // message-mode note that resolves to thread.contacts is scoped even when the
  // client sent no access_contacts.
  let resolvedAccessContactsSnapshot: string[] | null = null;
  let resolvedAccessGroupsSnapshot: string[] | null = null;

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertThreadAccess(trx, c.var.user.id, body.thread_id);

    // Resolve sharing model + current thread.contacts so the message-mode
    // invariant (always-explicit access_contacts) can be enforced.
    // Step 1: get thread.contacts and the earliest link (id, type, created_by).
    // Step 2: resolve link types via channel-level first, twist-level fallback,
    //         then find the sharingModel for the primary link's type.
    const threadWithLink = await trx
      .selectFrom("thread")
      .leftJoin("link", "link.thread_id", "thread.id")
      .select(["thread.contacts", "link.id as link_id", "link.type as link_type", "link.created_by as link_created_by"])
      .where("thread.id", "=", body.thread_id)
      .orderBy("link.created_at", "asc")
      .executeTakeFirst();

    let sharingModel: SharingModel = "thread";
    if (
      threadWithLink?.link_id &&
      threadWithLink.link_created_by &&
      threadWithLink.link_type
    ) {
      const allLinkTypes = await getLinkTypesForLink(
        trx,
        threadWithLink.link_id,
        threadWithLink.link_created_by,
      );
      const matched = allLinkTypes.find(
        (lt) => lt.type === threadWithLink.link_type,
      );
      if (matched?.sharingModel) sharingModel = matched.sharingModel;
    }

    const resolvedAccessContacts = resolveAccessContactsForSend({
      bodyAccessContacts: body.access_contacts ?? null,
      sharingModel,
      threadContacts: (threadWithLink?.contacts ?? []) as string[],
    });

    const resolvedAccessGroups = resolveAccessGroupsForSend({
      bodyAccessGroups: body.access_groups ?? null,
    });

    // Hoist the resolved values for the background scope branch below.
    resolvedAccessContactsSnapshot = resolvedAccessContacts;
    resolvedAccessGroupsSnapshot = resolvedAccessGroups;

    return rpcUser(trx, "upsert_note", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_author_id: body.author_id,
      p_created_by: body.created_by || c.var.user.id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
      p_thread_id: body.thread_id,
      p_draft: body.draft || false,
      p_access_contacts: (resolvedAccessContacts
        ? `{${resolvedAccessContacts.join(",")}}`
        : null) as any,
      p_access_groups: (resolvedAccessGroups
        ? `{${resolvedAccessGroups.join(",")}}`
        : null) as any,
      p_content: body.content || null,
      p_actions: body.actions || null,
      p_mentions: (Array.isArray(body.mentions)
        ? `{${body.mentions.join(",")}}`
        : null) as any,
      p_re_note_id: body.re_note_id || null,
      p_source_created_at: body.source_created_at || null,
      p_key: body.key || null,
      p_merged_from_thread_id: body.merged_from_thread_id || null,
    });
  });

  const priorityId = await getPriorityForThread(c.var.db, body.thread_id, c.var.user.id);
  notifySync(c, priorityId);

  // Notify mentioned twists so they receive the onNoteCreated callback.
  // SyncNotify.notifyTwists() only notifies priority-owner twists, so
  // mention-based routing needs an explicit wake-up for any twist not
  // owned by the priority owner.
  if (Array.isArray(body.mentions) && body.mentions.length > 0 && !body.draft) {
    try {
      const accountTwists = await c.var.db
        .selectFrom("twist_instance")
        .select("id")
        .where("id", "in", body.mentions)
        .where("archived_at", "is", null)
        .execute();

      for (const twist of accountTwists) {
        const twistSyncId = c.env.TWIST_SYNC.idFromName(twist.id);
        const twistSyncDO = c.env.TWIST_SYNC.get(twistSyncId);
        c.executionCtx.waitUntil(
          twistSyncDO.fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ id: twist.id }),
            })
          )
        );
      }
    } catch (error) {
      const logger = createLogger({ operation: "notifyAccountTwists" });
      logger.error(
        "Error notifying account-level twist DOs",
        error as Error
      );
    }
  }

  // Background processing: AI analysis + unread marking (best-effort, don't block the response)
  // Uses its own DB connection since the request-scoped one is destroyed after the response
  // Only run for new notes — re-analyzing on edits causes the AI to re-apply removed tags
  const noteId = (result as any)?.id ?? body.id;
  const content = body.content as string | null;
  if (noteId && !body.draft && !body.archived_at && !isUpdate) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createFrontendDb(c.env);
        try {
          // 1. Generate embedding (independent of notification pipeline)
          let aiAllowed: {
            allowed: boolean;
            chargeUserId: string | null;
          } | null = null;
          if (content && content.trim().length > 0) {
            // Get all thread contacts + note access contacts to check limits against
            const thread = await db
              .selectFrom("thread")
              .select("contacts")
              .where("id", "=", body.thread_id)
              .executeTakeFirst();
            const contactIds = [
              ...new Set([
                ...(thread?.contacts ?? []),
                ...(body.access_contacts ?? []),
              ]),
            ];

            const [aiEnabled, aiLimit] = await Promise.all([
              isAiEnabled(db, c.var.user.id),
              checkAiLimitForContacts(
                c.env,
                db,
                contactIds,
                c.var.user.id,
                "note_processing"
              ),
            ]);

            // Embedding generation is cheap (bge-small runs in-network) and
            // powers core focus-matching / classification, so it is NOT subject
            // to the free-tier note_processing quota — only the user's
            // built-in-AI opt-out (isAiEnabled). The per-plan history import
            // window already bounds how many notes a free user can sync. The
            // expensive LLM analysis below keeps its quota (aiAllowed).
            if (aiEnabled) {
              try {
                const response = (await c.env.AI.run(
                  "@cf/baai/bge-small-en-v1.5",
                  {
                    text: content,
                  }
                )) as { data: number[][] };
                const embedding = response.data[0];
                await db
                  .updateTable("note")
                  .set({ embedding: JSON.stringify(embedding) })
                  .where("id", "=", noteId)
                  .execute();
              } catch (error) {
                console.error(
                  "[embedding:sync] Failed to generate embedding for note",
                  noteId,
                  error
                );
              }
            }

            // Expensive AI analysis (thread_state generation) still respects the
            // free-tier note_processing quota.
            if (aiEnabled && aiLimit.allowed) {
              aiAllowed = aiLimit;
            }
          }

          const scoped = isScopedNote(
            resolvedAccessContactsSnapshot,
            resolvedAccessGroupsSnapshot
          );

          // 2. Try AI analysis first — creates targeted thread_state rows (skipped for AI=none output)
          //
          // Scoped notes skip AI unread analysis entirely: the DB trigger
          // update_thread_on_note_change owns per-user unread for exactly the
          // note-visible set, and AI targeting could mark unread for users
          // OUTSIDE the note's access scope — leaking a private reply to the
          // broadcast audience.
          let analysisHandledUnread = false;
          if (!scoped && aiAllowed) {
            const isRecent =
              !body.source_created_at ||
              Date.now() - new Date(body.source_created_at).getTime() <
                7 * 24 * 60 * 60 * 1000;
            if (isRecent) {
              try {
                analysisHandledUnread = await analyzeNote(
                  c.env,
                  noteId,
                  body.thread_id,
                  c.var.user.id
                );
              } catch (error) {
                const logger = createLogger({
                  operation: "sync:notes:analyzeNote",
                });
                logger.error("Failed to analyze note", error as Error, {
                  note_id: noteId,
                });
                c.var.tracker.captureException(error as Error);
              }
            }

            if (aiAllowed.chargeUserId) {
              recordAiUsage(c.env, aiAllowed.chargeUserId, "note_processing");
            }
          }

          // 3. Resolve who to push to / mark unread.
          //
          // SCOPED notes (resolved access_contacts/groups non-null): the DB
          // trigger update_thread_on_note_change already owns the per-user
          // re-emit + unread for exactly the note-visible set. The API must
          // therefore NOT mark unread itself (that would double-write and could
          // unread users outside the scope) — it only PUSHES, and only to the
          // users who can see the note. We derive scoped-ness from the RESOLVED
          // access values passed to upsert_note (snapshotted above), not raw
          // body.access_*, so the API and the trigger agree on the visible set.
          //
          // UNSCOPED notes: keep today's analyze / markThreadUnreadForOthers
          // fan-out to the whole thread-visible audience unchanged.
          let affectedUserIds: string[] = [];
          if (scoped) {
            try {
              affectedUserIds = await noteVisibleUserIds(
                db,
                body.thread_id,
                c.var.user.id,
                resolvedAccessContactsSnapshot,
                resolvedAccessGroupsSnapshot,
                c.var.user.id
              );
            } catch (error) {
              const logger = createLogger({
                operation: "sync:notes:noteVisibleUserIds",
              });
              logger.error(
                "Failed to resolve note-visible users for scoped note",
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          } else if (!analysisHandledUnread) {
            try {
              affectedUserIds = await markThreadUnreadForOthers(
                c.env,
                db,
                body.thread_id,
                c.var.user.id,
                new Date().toISOString()
              );
            } catch (error) {
              const logger = createLogger({
                operation: "sync:notes:markUnread",
              });
              logger.error(
                "Failed to mark thread unread for others",
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          } else {
            // Analysis handled unread — still need to collect user IDs for DO notification
            try {
              const thread = await db
                .selectFrom("thread")
                .select("contacts")
                .where("id", "=", body.thread_id)
                .executeTakeFirst();

              if (thread?.contacts && thread.contacts.length > 0) {
                const users = await db
                  .selectFrom("user_contact")
                  .select("user_id")
                  .where("contact_id", "in", thread.contacts as string[])
                  .where("linked", "=", true)
                  .where("archived_at", "is", null)
                  .execute();

                const userIds = [...new Set(users.map((u) => u.user_id))];
                affectedUserIds = userIds.filter((id) => id !== c.var.user.id);
              }
            } catch (error) {
              const logger = createLogger({ operation: "sync:notes:getUsers" });
              logger.error(
                "Failed to get thread users for DO notification",
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          }

          // 4. Notify UserSync DOs — triggers push notification pipeline
          for (const userId of affectedUserIds) {
            try {
              const userSyncId = c.env.USER_SYNC.idFromName(userId);
              const userSyncDO = c.env.USER_SYNC.get(userSyncId);
              await userSyncDO.fetch(
                new Request("http://do/notify", {
                  method: "POST",
                  body: JSON.stringify({ id: userId }),
                })
              );
            } catch (error) {
              const logger = createLogger({
                operation: "sync:notes:notifyUserSync",
              });
              logger.error(
                `Failed to notify UserSync for user ${userId}`,
                error as Error
              );
              c.var.tracker.captureException(error as Error);
            }
          }
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

/**
 * A note is SCOPED when it carries a non-null access scope (contacts and/or
 * groups). For scoped notes the DB trigger `update_thread_on_note_change`
 * owns the per-user re-emit + unread, so the API must NOT mark unread itself
 * (no double-write) and must only push to the note-visible set. An explicit
 * empty array still counts as a scope (author-only), so test for non-null —
 * never truthiness/length.
 */
export function isScopedNote(
  resolvedAccessContacts: string[] | null,
  resolvedAccessGroups: string[] | null,
): boolean {
  return resolvedAccessContacts != null || resolvedAccessGroups != null;
}

/**
 * Users (other than `excludeUserId`) who can SEE a scoped note: filed on the
 * thread (thread_priority, not revoked) AND matching the note's access scope
 * (author, or access_contacts overlaps their contacts, or access_groups
 * overlaps their groups). Mirrors the user.note view's visibility predicate
 * and the SELECT inside update_thread_on_note_change's scoped branch, so the
 * API push set matches exactly the set the DB trigger re-emits/unreads.
 */
export async function noteVisibleUserIds(
  db: Kysely<DB>,
  threadId: string,
  createdBy: string,
  accessContacts: string[] | null,
  accessGroups: string[] | null,
  excludeUserId: string,
): Promise<string[]> {
  const rows = await sql<{ user_id: string }>`
    SELECT DISTINCT tp.user_id
    FROM thread_priority tp
    WHERE tp.thread_id = ${threadId}::uuid
      AND tp.revoked_at IS NULL
      AND (
        tp.user_id = ${createdBy}::uuid
        OR ${
          accessContacts
            ? sql`${accessContacts}::uuid[] && "user".user_contact_ids(tp.user_id)`
            : sql`FALSE`
        }
        OR ${
          accessGroups
            ? sql`${accessGroups}::uuid[] && "user".user_group_ids(tp.user_id)`
            : sql`FALSE`
        }
      )
  `.execute(db);
  return rows.rows.map((r) => r.user_id).filter((id) => id !== excludeUserId);
}

/**
 * Mark a thread as unread for all priority members except the excluded user.
 * Creates a row with all three state booleans false and importance 50 —
 * used as a fallback when AI analysis doesn't run or fails. The thread is
 * still unread (read_at NULL) so it shows in Updates.
 * Returns the list of user IDs that were successfully marked unread.
 */
export async function markThreadUnreadForOthers(
  env: Bindings,
  db: Kysely<DB>,
  threadId: string,
  excludeUserId: string,
  noteCreatedAt?: string
): Promise<string[]> {
  // Get all thread contacts and groups
  const thread = await db
    .selectFrom("thread")
    .select(["contacts", "groups"])
    .where("id", "=", threadId)
    .executeTakeFirst();

  if (!thread) return [];
  const contacts = (thread.contacts ?? []) as string[];
  const groups = (thread.groups ?? []) as string[];
  if (contacts.length === 0 && groups.length === 0) return [];

  // Resolve every user with visibility: linked to any thread contact,
  // OR a member of any thread group (via their linked contacts).
  const userRows = await sql<{ user_id: string }>`
    SELECT DISTINCT uc.user_id
    FROM user_contact uc
    WHERE uc.linked = TRUE
      AND uc.archived_at IS NULL
      AND (
        ${contacts.length > 0 ? sql`uc.contact_id = ANY(${contacts}::uuid[])` : sql`FALSE`}
        OR EXISTS (
          SELECT 1 FROM group_member gm
          WHERE gm.contact_id = uc.contact_id
            AND ${groups.length > 0 ? sql`gm.group_id = ANY(${groups}::uuid[])` : sql`FALSE`}
        )
      )
  `.execute(db);

  const userIds = [...new Set(userRows.rows.map((r) => r.user_id))];

  const markedUserIds: string[] = [];
  for (const userId of userIds) {
    if (userId === excludeUserId) continue;

    try {
      await rpcUser(db, "upsert_thread_state", {
        user_id: userId,
        p_thread_id: threadId,
        p_active: false,
        p_urgent: false,
        p_importance: 50,
        // p_read_at omitted → defaults to NULL; combined with
        // p_set_read_at: true this marks the thread unread (race-safe
        // when p_note_created_at is set).
        p_set_active: false,
        p_set_urgent: true,
        p_set_importance: true,
        p_set_read_at: true,
        ...(noteCreatedAt ? { p_note_created_at: noteCreatedAt } : {}),
      });

      markedUserIds.push(userId);
    } catch (error) {
      const logger = createLogger({ operation: "markThreadUnreadForOthers" });
      logger.error(
        `Failed to mark thread unread for user ${userId}`,
        error as Error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(error as Error, userId, {
        context: "markThreadUnreadForOthers",
        thread_id: threadId,
      });
      await postHog.shutdown();
    }
  }

  return markedUserIds;
}

export default notes;
