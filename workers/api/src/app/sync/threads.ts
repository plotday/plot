import { Hono } from "hono";

import { sql, withDb, withUserDb, createDb } from "../../db";
import type { Bindings } from "../../env";
import { rpc, rpcUser } from "../../rpc";
import {
  classifyThreadForUser,
  dispatchPendingForThread,
  enqueueJobs,
} from "../../state/classify-thread";
import { checkAiLimit, recordAiUsage } from "../../utils/ai-limits";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../../utils/ai-provider";
import { cleanTitle } from "../../twist/tools/plot/thread";
import { titleFromContent, createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
import { summarize } from "../summary";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { createLogger } from "@plotday/worker-util";
import { sendInvitation } from "../invitation";
import { notifySync, notifyUserSyncByEnv } from "./notify";
import { stripAnnounceContactsFromThreads } from "./viewer";
import { twistFactory } from "../../twist/factory";

const threads = new Hono<{ Bindings: Bindings }>();

// GET /sync/threads
threads.get("/sync/threads", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    initial,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort: use custom sort when not doing cursor pagination
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc");
    } else if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      // When sorting by agenda_at (a tstzrange), sort by its lower bound
      const sortExpr = sortBy === 'agenda_at' ? sql`lower(agenda_at)` : sql.ref(sortBy);
      query = query.orderBy(sortExpr, sortDir).orderBy("id", sortDir);
    }

    // Don't apply limit for initial pulls — except when seq-cursor is in use,
    // where the envelope semantics rely on the limit signaling end-of-page.
    // Seq-cursor clients paginate naturally from `seq=0` on first pull and
    // can drain in multiple round-trips; old clients still get the
    // unbounded initial response.
    if (!initial || useSeqCursor) {
      query = query.limit(limit);
    }

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (useSeqCursor) {
      query = query.where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      // Legacy: uses date_trunc to match JS Date millisecond precision
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Initial pull: fetch unread non-archived threads
    if (initial && archived !== true) {
      query = query.where(
        sql<boolean>`(archived_at IS NULL AND draft = false AND unread = true)`
      );
    } else {
      // Archived filter (only when not initial)
      if (archived === true) {
        query = query.where("archived_at", "is not", null);
      } else if (archived === false) {
        query = query.where("archived_at", "is", null);
      }
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering (for pullTo pagination by sortBy column)
    if (sortBy === 'agenda_at') {
      // agenda_at is a tstzrange — use overlap (&&) operator
      if (rangeStart && rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, ${rangeEnd}::timestamptz)`);
      } else if (rangeStart) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, NULL)`);
      } else if (rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(NULL, ${rangeEnd}::timestamptz)`);
      }
    } else {
      // Scalar comparison for activity_at, created_at, updated_at
      if (rangeStart) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
      }
      if (rangeEnd) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
      }
    }

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  await stripAnnounceContactsFromThreads(c.var.db, userId, rows as any);

  // Version-gated serialization: apiVersion < 3 clients expect a `topics`
  // array (the legacy name for what is now `groups`). Map groups → topics
  // and drop the new `topic` / `groups` fields for those clients.
  const apiVersion = c.var.apiVersion ?? 0;
  const transform = (row: any) => {
    if (apiVersion < 3) {
      const { groups, topic: _topic, ...rest } = row;
      return { ...rest, topics: groups ?? [] };
    }
    return row;
  };
  const outRows = rows.map(transform);

  if (useSeqCursor) {
    return c.json(seqEnvelope(outRows as any, limit, horizon) as any);
  }
  return c.json(outRows as any);
});

// GET /sync/threads/by-ids?ids=uuid1,uuid2,...
//
// Out-of-band fetch of a small set of threads by id. Returns the same row
// shape as GET /sync/threads but skips the seq-cursor envelope (callers
// hydrate via insertOrReplace without touching their sync cursor). Capped
// at 50 ids; intended for the notification-tap fast path where we know
// exactly which threads we need ahead of normal cursor pulls.
threads.get("/sync/threads/by-ids", async (c) => {
  const userId = c.var.user.id;
  const idsRaw = c.req.query("ids") ?? "";
  const ids = idsRaw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  // Validate as UUIDs (case-insensitive) and cap the batch size so a
  // crafted url can't pull arbitrary amounts of data.
  const uuidRe =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const validIds = ids.filter((id) => uuidRe.test(id)).slice(0, 50);
  if (validIds.length === 0) {
    return c.json([]);
  }

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    return await trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId)
      .where("id", "in", validIds)
      .execute();
  });

  await stripAnnounceContactsFromThreads(c.var.db, userId, rows as any);

  const apiVersion = c.var.apiVersion ?? 0;
  const transform = (row: any) => {
    if (apiVersion < 3) {
      const { groups, topic: _topic, ...rest } = row;
      return { ...rest, topics: groups ?? [] };
    }
    return row;
  };
  return c.json(rows.map(transform) as any);
});

// GET /sync/threads/search - Full-text style search across threads, notes, and links.
// Returns rows from user.thread (same shape as GET /sync/threads) so the client
// can hydrate into the local store and render results. When count_only=true,
// returns { count } instead of rows — used by the client to decide whether to
// surface a "view archived matches" hint without fetching the rows themselves.
threads.get("/sync/threads/search", async (c) => {
  const userId = c.var.user.id;
  const q = (c.req.query("q") ?? "").trim();
  const archivedRaw = c.req.query("archived");
  const archived =
    archivedRaw === "true" ? true : archivedRaw === "false" ? false : undefined;
  const countOnly = c.req.query("count_only") === "true";
  const priorityId = c.req.query("priority_id") || null;
  const limitRaw = c.req.query("limit");
  const limit = limitRaw
    ? Math.min(Math.max(1, parseInt(limitRaw, 10) || 50), 200)
    : 50;

  if (!q) {
    return countOnly ? c.json({ count: 0 }) : c.json([]);
  }

  // Escape ILIKE wildcards and build a contains-pattern.
  const escapeIlike = (s: string) =>
    s.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
  const escaped = escapeIlike(q);
  const pattern = `%${escaped}%`;

  // Word-split for contact-name matching: each word must match at least one
  // contact on the thread (different contacts may match different words,
  // mirroring the client-side semantics).
  const contactWords = q
    .split(/\s+/)
    .filter((w) => w.length > 0)
    .map((w) => w.toLowerCase())
    .filter((w) => w.length >= 2);

  const archivedExpr =
    archived === true
      ? sql<boolean>`ut.archived_at IS NOT NULL`
      : archived === false
        ? sql<boolean>`ut.archived_at IS NULL`
        : sql<boolean>`true`;

  const priorityExpr = priorityId
    ? sql<boolean>`ut.priority_id IN (SELECT child_id FROM public.priority_child WHERE priority_id = ${priorityId}::uuid)`
    : sql<boolean>`true`;

  // Build the optional contact branch. Skipped when no usable words remain
  // after the length filter so we don't return every thread that has any
  // contact on it.
  let contactBranch: ReturnType<typeof sql<boolean>> | null = null;
  if (contactWords.length > 0) {
    const wordClauses = contactWords.map((word) => {
      const e = escapeIlike(word);
      const startPattern = `${e}%`;
      const innerPattern = `% ${e}%`;
      return sql<boolean>`EXISTS (
        SELECT 1 FROM public.contact c
        WHERE c.archived_at IS NULL
          AND c.id = ANY(ut.contacts)
          AND (
            c.name ILIKE ${startPattern}
            OR c.name ILIKE ${innerPattern}
            OR c.email ILIKE ${startPattern}
          )
      )`;
    });
    contactBranch = wordClauses.reduce(
      (acc, clause) => sql<boolean>`${acc} AND ${clause}`,
    );
  }

  const matchExpr = sql<boolean>`(
    ut.title ILIKE ${pattern}
    OR EXISTS (
      SELECT 1 FROM public.note n
      WHERE n.thread_id = ut.id
        AND n.archived_at IS NULL
        AND n.draft = false
        AND n.content ILIKE ${pattern}
    )
    OR EXISTS (
      SELECT 1 FROM public.link l
      WHERE l.thread_id = ut.id
        AND (l.title ILIKE ${pattern} OR l.source_url ILIKE ${pattern} OR l.preview ILIKE ${pattern})
    )
    ${contactBranch ? sql`OR (${contactBranch})` : sql``}
  )`;

  if (countOnly) {
    const count = await withUserDb(c.var.db, userId, async (trx) => {
      const result = await sql<{ count: string }>`
        SELECT count(*)::text AS count
        FROM "user".thread ut
        WHERE ut.user_id = ${userId}::uuid
          AND ${archivedExpr}
          AND ${priorityExpr}
          AND ${matchExpr}
      `.execute(trx);
      return parseInt(result.rows[0]?.count ?? "0", 10) || 0;
    });
    return c.json({ count });
  }

  const resultRows = await withUserDb(c.var.db, userId, async (trx) => {
    const result = await sql<any>`
      SELECT ut.*
      FROM "user".thread ut
      WHERE ut.user_id = ${userId}::uuid
        AND ${archivedExpr}
        AND ${priorityExpr}
        AND ${matchExpr}
      ORDER BY ut.activity_at DESC
      LIMIT ${limit}
    `.execute(trx);
    return result.rows;
  });

  await stripAnnounceContactsFromThreads(c.var.db, userId, resultRows as any);

  // Version-gated serialization: apiVersion < 3 clients expect `topics` instead
  // of `groups` (same shim as GET /sync/threads above).
  const apiVersion = c.var.apiVersion ?? 0;
  if (apiVersion < 3) {
    const legacyRows = resultRows.map((row: any) => {
      const { groups, topic: _topic, ...rest } = row;
      return { ...rest, topics: groups ?? [] };
    });
    return c.json(legacyRows as any);
  }

  return c.json(resultRows as any);
});

// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();

  // Capture create-link fields before they're stripped. `threadData` can be
  // the same reference as `body` (when the client sends a flat body with no
  // `thread` wrapper), so a later `delete threadData.create_link` would
  // also clear `body.create_link` if we didn't snapshot here.
  const createLinkSpec = body.create_link as
    | {
        twist_instance_id?: string;
        channel_id?: string;
        type?: string;
        status?: string;
      }
    | undefined;
  const noteContent = (body.note_content as string | null | undefined) ?? null;

  const threadData = body.thread || body;

  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  // Generate AI title when client sends title=null with preview content
  if (
    !threadData.title &&
    threadData.preview &&
    typeof threadData.preview === "string" &&
    threadData.draft !== true
  ) {
    try {
      const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");
      if (aiAllowed.allowed) {
        const providerConfig = await loadBuiltinProviderConfig(c.var.db, c.var.user.id, c.env);
        let aiTitle: string | null = null;

        if (providerConfig) {
          aiTitle = await summarizeWithProvider(providerConfig, threadData.preview);
        }
        if (!aiTitle) {
          const result = await summarize(c.env.AI, threadData.preview);
          aiTitle = result.title;
        }

        if (aiTitle) {
          recordAiUsage(c.env, c.var.user.id, "note_processing");
          threadData.title = aiTitle;
        }
      }
    } catch (error) {
      console.error("[sync/threads] AI title generation failed:", error);
      c.var.tracker.captureException(error as Error);
    }

    // Fallback: derive title from content if AI didn't produce one
    if (!threadData.title) {
      threadData.title = titleFromContent(threadData.preview) ?? "Untitled";
    }

    // Truncate preview for storage now that title is set
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  // Always truncate oversized preview (e.g. client set title via /summary but preview is still full content)
  if (threadData.preview && typeof threadData.preview === "string" && threadData.preview.length > 200) {
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  // Extract invite_emails before passing to upsert_thread (not a DB column)
  const inviteEmails: string[] = Array.isArray(threadData.invite_emails)
    ? threadData.invite_emails
    : [];
  delete threadData.invite_emails;

  // Strip server-side-only fields. twist_id is set by the twist runtime and
  // must not be settable via the user-facing sync endpoint — otherwise a
  // caller could dedupe their thread into someone else's twist-owned thread
  // and gain unintended visibility. pending_contacts is managed internally
  // by upsert_thread and the peer-promotion logic.
  delete threadData.twist_id;
  delete threadData.pending_contacts;
  // create_link and note_content are client→server control fields for the
  // connector-backed create-new-item flow; they are not thread columns.
  delete threadData.create_link;
  delete threadData.note_content;

  // Translate legacy `topics` field (apiVersion < 3) to `groups` so
  // upsert_thread sees the new shape. If both are present, `groups` wins.
  if (threadData.topics !== undefined && threadData.groups === undefined) {
    threadData.groups = threadData.topics;
  }
  delete threadData.topics;

  const userId = c.var.user.id;

  // Set when the user's explicit priority pick transitions this thread's
  // thread_priority.user_moved from FALSE to TRUE — i.e. this save is the
  // first filing signal. Used post-response to kick off retroactive
  // reclassification of the user's other threads against the new training
  // example (mirrors POST /sync/priority-moves).
  let userMovedTransitioned = false;

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const upsertResult = await rpcUser(trx, "upsert_thread", {
      user_id: userId,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Auto-classify: when the client signals auto_file, score the thread
    // against the user's explicitly-moved training threads via
    // classify_thread_for_user. The function reads topic/contacts/groups
    // directly from the thread row (via p_thread_id), so no extra params
    // are needed. We guard the UPDATE on user_moved = FALSE so the user's
    // own filing choice is never overwritten by an auto-classify pass.
    if (body.auto_file && !threadData.draft && upsertResult) {
      try {
        const textToEmbed = threadData.title || threadData.preview;
        let queryEmbedding: string | undefined;
        if (textToEmbed) {
          const response = (await c.env.AI.run("@cf/baai/bge-small-en-v1.5", {
            text: textToEmbed,
          })) as { data: number[][] };
          queryEmbedding = JSON.stringify(response.data[0]);

          await sql`UPDATE thread SET embedding = ${sql.val(queryEmbedding!)}::halfvec
                    WHERE id = ${sql.val(upsertResult.id)}`.execute(trx);
        }
        const matched = await classifyThreadForUser(trx, c.env, {
          userId,
          threadId: upsertResult.id,
          embedding: queryEmbedding ?? null,
        });
        if (matched.priorityId !== threadData.priority_id || matched.pending) {
          await sql`UPDATE thread_priority
                       SET priority_id = ${sql.val(matched.priorityId)},
                           classify_at = ${matched.pending ? sql`now()` : sql`NULL`}
                     WHERE thread_id = ${sql.val(upsertResult.id)}
                       AND user_id = ${sql.val(userId)}
                       AND user_moved = FALSE`.execute(trx);
        }
      } catch (error) {
        console.error("[sync/threads] Auto-classification failed:", error);
        c.var.tracker.captureException(error as Error);
      }
    } else if (
      threadData.priority_id &&
      !threadData.draft &&
      upsertResult
    ) {
      // Explicit user priority pick on a finalized (non-draft) thread is the
      // same filing signal as POST /sync/priority-moves. Flip user_moved to
      // TRUE so this row joins the classifier's training set and stops being
      // eligible for automatic re-filing. Guard on user_moved = FALSE so
      // unrelated saves (title edits, etc.) don't repeatedly re-fire the
      // retroactive reclassify side-effect below.
      const transitioned = await sql<{ thread_id: string }>`
        UPDATE thread_priority
        SET user_moved = TRUE, updated_at = now()
        WHERE thread_id = ${sql.val(upsertResult.id)}
          AND user_id = ${sql.val(userId)}
          AND user_moved = FALSE
        RETURNING thread_id
      `.execute(trx);
      if (transitioned.rows.length > 0) {
        userMovedTransitioned = true;
      }
    }

    return upsertResult;
  });

  // Dispatch classify jobs for peer thread_priority rows the upsert
  // triggers wrote as pending (and the author's row if foreground
  // classify failed). Runs in waitUntil after the transaction commits;
  // opens its own DB handle because the request-scoped one is destroyed
  // by then.
  if (result?.id) {
    const threadId = result.id as string;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          await dispatchPendingForThread(db, c.env, threadId);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  // After a first-time explicit filing, retroactively mark the user's
  // other threads pending re-classification against the newly-expanded
  // training set. Mirrors the waitUntil block in POST /sync/priority-moves.
  // mark_reclassify_candidates returns (user_id, thread_id) rows that the
  // consumer Worker drains via enqueueJobs.
  if (userMovedTransitioned && result) {
    const reclassifyThreadId = result.id;
    c.executionCtx.waitUntil(
      (async () => {
        const logger = createLogger({ component: "sync-threads-reclassify" });
        try {
          await withDb(c.env, async (db) => {
            const marked = await sql<{ user_id: string; thread_id: string }>`
              SELECT user_id::text AS user_id, thread_id::text AS thread_id
                FROM public.mark_reclassify_candidates(
                  ${userId}::uuid, ${reclassifyThreadId}::uuid)
            `.execute(db);
            await enqueueJobs(
              c.env,
              marked.rows.map((r) => ({
                userId: r.user_id,
                threadId: r.thread_id,
              }))
            );
            await notifyUserSyncByEnv(c.env, userId);
          });
        } catch (error) {
          logger.error("Retroactive reclassify failed", error as Error, {
            user_id: userId,
            thread_id: reclassifyThreadId,
          });
          c.var.tracker.captureException(error as Error);
        }
      })()
    );
  }

  // Process pending email invitations: resolve emails → contacts, add to
  // thread.contacts via share_thread, send invitation emails.
  if (inviteEmails.length > 0 && result) {
    const logger = createLogger({ component: "sync-threads-invite" });
    try {
      // Resolve emails to contact UUIDs
      const contacts = await rpc(c.var.db, "upsert_contacts", {
        contacts: JSON.stringify(inviteEmails.map((email: string) => ({ email: email.toLowerCase() }))),
      });
      const contactRows = Array.isArray(contacts) ? contacts : [contacts];
      const contactIds = contactRows.map((row: { id: string }) => row.id);

      if (contactIds.length > 0) {
        // Add resolved contacts to thread via share_thread (handles
        // thread_unread creation and returns needs_invitation list)
        const shareResult = await c.var.db.transaction().execute(async (trx) => {
          return rpc(trx, "share_thread", {
            p_user_id: userId,
            p_thread_id: result.id,
            p_add_contact_ids: `{${contactIds.join(",")}}` as any,
            p_remove_contact_ids: "{}" as any,
          });
        }) as unknown as { contacts: string[]; needs_invitation: string[] };

        // Send invitation emails for contacts not linked to a user
        const needsInvitation = shareResult.needs_invitation ?? [];
        for (const contactId of needsInvitation) {
          try {
            await sendInvitation(c.var.db, {
              contactId,
              threadId: result.id,
              inviterUserId: userId,
              mailQueue: c.env.MAIL_QUEUE,
              appRoot: c.env.APP_ROOT,
            });
          } catch (inviteError) {
            logger.error("Invitation email failed", inviteError as Error, {
              contact_id: contactId,
              thread_id: result.id,
            });
            c.var.tracker.captureException(inviteError as Error, {
              contact_id: contactId,
              thread_id: result.id,
              error_context: "sync_thread_invitation_email_failed",
            });
          }
        }
      }
    } catch (error) {
      // Email invitation processing is non-critical — log but don't fail the sync
      console.error("[sync/threads] Email invitation processing failed:", error);
      c.var.tracker.captureException(error as Error);
    }
  }

  notifySync(c, threadData.priority_id);

  // Dispatch to connector to create a new external item when the client
  // requested it. Fire-and-forget via waitUntil so the thread response
  // returns immediately — the link will appear via sync once the connector
  // responds.
  if (
    createLinkSpec?.twist_instance_id &&
    createLinkSpec.channel_id &&
    createLinkSpec.type &&
    createLinkSpec.status &&
    result &&
    threadData.draft !== true
  ) {
    // Snapshot thread fields needed inside waitUntil — `c.var.db` is torn
    // down once the response returns, so we spin up a fresh connection.
    const dispatchContactIds: string[] = Array.isArray(threadData.contacts)
      ? (threadData.contacts as string[])
      : [];
    const dispatchTitle = threadData.title as string;
    const dispatchThreadId = result.id;

    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          // Resolve the thread's contacts into Actor rows for the connector,
          // excluding every contact linked to the creating user so the author
          // isn't passed as a recipient.
          const contacts: Array<{ id: string; type: "contact" | "user"; email: string | null; name: string | null }> = [];
          if (dispatchContactIds.length > 0) {
            const rows = await db
              .selectFrom("contact as c")
              .leftJoin("user_contact as uc", (join) =>
                join
                  .onRef("uc.contact_id", "=", "c.id")
                  .on("uc.user_id", "=", userId)
                  .on("uc.linked", "=", true)
                  .on("uc.archived_at", "is", null)
              )
              .select([
                "c.id",
                "c.email",
                "c.name",
                "uc.user_id as linked_user_id",
              ])
              .where("c.id", "in", dispatchContactIds)
              .execute();
            for (const row of rows) {
              if (row.linked_user_id) continue;
              contacts.push({
                id: row.id,
                type: "contact",
                email: row.email ?? null,
                name: row.name ?? null,
              });
            }
          }

          const draft = {
            channelId: createLinkSpec.channel_id!,
            type: createLinkSpec.type!,
            status: createLinkSpec.status!,
            title: dispatchTitle,
            noteContent,
            contacts,
          };

          const factory = twistFactory({
            env: c.env,
            ctx: c.executionCtx as any,
            db,
          });
          const wrapper = await factory({
            twistInstanceId: createLinkSpec.twist_instance_id!,
          });
          await wrapper.dispatch("Integrations", {
            itemType: "create_link",
            threadId: dispatchThreadId,
            draft,
          });
        } catch (error) {
          console.error("[sync/threads] create_link dispatch failed:", error);
          c.var.tracker.captureException(error as Error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

export default threads;
