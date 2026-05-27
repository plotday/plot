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

  // On initial sync (epoch or seq=0), the client has nothing to reconcile,
  // so the access-loss redacted stubs from user.thread_redacted are useless
  // noise. Skip that branch on initial pulls and only query it on incremental
  // syncs, matching the user.note / user.note_redacted pattern.
  const isInitialSync = useSeqCursor
    ? seqSince === "0"
    : !updatedSince || updatedSince === "1970-01-01T00:00:00.000Z";

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    const buildQuery = (view: "user.thread" | "user.thread_redacted") => {
      let query = trx
        .selectFrom(view)
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

      // Initial pull: fetch unread non-archived threads. Redacted stubs are
      // archived by definition, so this branch naturally excludes them.
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

      return query;
    };

    const visible = await buildQuery("user.thread").execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";

    if (isInitialSync) {
      return { rows: visible, horizon: horizonValue };
    }

    const redacted = await buildQuery("user.thread_redacted").execute();

    // Merge and re-sort across both sets, then slice to the requested limit.
    // Each server-side query is already bounded by `limit`; the redacted set
    // is typically tiny (only rows where the user lost access since last sync).
    const merged = [...visible, ...redacted];
    if (useSeqCursor) {
      merged.sort((a, b) => {
        const as = (a as any).seq ?? "0";
        const bs = (b as any).seq ?? "0";
        if (as !== bs) return as < bs ? -1 : 1;
        const aid = (a as any).id ?? "";
        const bid = (b as any).id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    } else {
      merged.sort((a, b) => {
        const au = (a as any).updated_at ? (a as any).updated_at.getTime() : 0;
        const bu = (b as any).updated_at ? (b as any).updated_at.getTime() : 0;
        if (au !== bu) return au - bu;
        const aid = (a as any).id ?? "";
        const bid = (b as any).id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    }
    const limitToApply = !initial || useSeqCursor ? limit : merged.length;
    return { rows: merged.slice(0, limitToApply), horizon: horizonValue };
  });

  await stripAnnounceContactsFromThreads(c.var.db, userId, rows as any);

  // TODO(contact-roles): when a connector starts emitting hidden roles (e.g.
  // Gmail BCC), filter contact_meta entries here based on the role config's
  // `hidden` flag — keep the entry only when the requesting user is either
  // the contact (linked via user_contact) or the `addedBy` user. Until then
  // every entry is visible to every viewer.

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
    const visible = await trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId)
      .where("id", "in", validIds)
      .execute();
    // Also fetch redacted stubs so tapping a notification for a thread the
    // user has since lost access to still returns a row (the client can
    // then hard-delete its local copy).
    const seenIds = new Set(visible.map((r) => r.id));
    const remainingIds = validIds.filter((id) => !seenIds.has(id));
    if (remainingIds.length === 0) return visible;
    const redacted = await trx
      .selectFrom("user.thread_redacted")
      .selectAll()
      .where("user_id", "=", userId)
      .where("id", "in", remainingIds)
      .execute();
    return [...visible, ...redacted];
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

  // Require at least 2 characters before running the search. A 1-char query
  // becomes `%a%` and forces sequential ILIKE scans across the user's entire
  // thread/note/link/contact set, which reliably trips the Postgres statement
  // timeout for users with substantial data. (Proper long-term fix is
  // pg_trgm GIN indexes on the searched columns.)
  if (q.length < 2) {
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

  // Candidate-id subquery: union of trgm-indexed table scans. Each branch
  // uses an existing GIN trgm index on the base table so the planner can
  // resolve it with an index scan, instead of trapping the ILIKE inside an
  // OR-EXISTS over the expensive user.thread view (which forces per-row
  // recomputation of activity_at / agenda_at and reliably trips the
  // statement timeout for users with substantial data).
  const titleBranch = sql`
    SELECT id FROM public.thread WHERE title ILIKE ${pattern}
  `;
  const noteBranch = sql`
    SELECT thread_id AS id FROM public.note
    WHERE archived_at IS NULL AND draft = false AND content ILIKE ${pattern}
  `;
  const linkBranch = sql`
    SELECT thread_id AS id FROM public.link
    WHERE title ILIKE ${pattern} OR source_url ILIKE ${pattern} OR preview ILIKE ${pattern}
  `;

  // Contact-name branch: each word must match at least one (possibly
  // different) contact on the thread. Per-word, we find threads whose
  // contacts array intersects the set of matching contacts (uses
  // contact.name / contact.email trgm indexes + thread.contacts gin
  // index), then INTERSECT across words.
  let contactBranchCandidates: ReturnType<typeof sql> | null = null;
  if (contactWords.length > 0) {
    const perWord = contactWords.map((word) => {
      const e = escapeIlike(word);
      const startPattern = `${e}%`;
      const innerPattern = `% ${e}%`;
      return sql`
        SELECT t.id FROM public.thread t
        WHERE t.contacts && (
          SELECT COALESCE(array_agg(c.id), ARRAY[]::uuid[])
          FROM public.contact c
          WHERE c.archived_at IS NULL
            AND (
              c.name ILIKE ${startPattern}
              OR c.name ILIKE ${innerPattern}
              OR c.email ILIKE ${startPattern}
            )
        )
      `;
    });
    contactBranchCandidates = perWord.reduce(
      (acc, q) => sql`${acc} INTERSECT ${q}`,
    );
  }

  const candidateIds = contactBranchCandidates
    ? sql`(${titleBranch}) UNION (${noteBranch}) UNION (${linkBranch}) UNION (${contactBranchCandidates})`
    : sql`(${titleBranch}) UNION (${noteBranch}) UNION (${linkBranch})`;

  if (countOnly) {
    const count = await withUserDb(c.var.db, userId, async (trx) => {
      const result = await sql<{ count: string }>`
        SELECT count(*)::text AS count
        FROM "user".thread ut
        WHERE ut.user_id = ${userId}::uuid
          AND ut.id IN (${candidateIds})
          AND ${archivedExpr}
          AND ${priorityExpr}
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
        AND ut.id IN (${candidateIds})
        AND ${archivedExpr}
        AND ${priorityExpr}
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

  // Track "Archive threads like this" intent the client passed in this
  // payload so we can fan out (apply rule) or revert (clear rule) after the
  // single-thread upsert completes. The flag is per-user (lives on
  // thread_priority), so we pre-read the previous value to decide what to
  // do when the client sends a null transition.
  const archiveSimilarSent = Object.prototype.hasOwnProperty.call(
    threadData,
    "auto_archived_by_thread_id"
  );
  const archiveSimilarValue: string | null = archiveSimilarSent
    ? (threadData.auto_archived_by_thread_id as string | null) ?? null
    : null;
  let archiveSimilarPrevSeed: string | null = null;
  if (archiveSimilarSent && threadData.id) {
    const prev = await sql<{ auto_archived_by_thread_id: string | null }>`
      SELECT auto_archived_by_thread_id
      FROM public.thread_priority
      WHERE thread_id = ${sql.val(threadData.id)}::uuid
        AND user_id = ${sql.val(userId)}::uuid
    `.execute(c.var.db);
    archiveSimilarPrevSeed = prev.rows[0]?.auto_archived_by_thread_id ?? null;
  }

  // Count of threads the rule touched (for the PostHog event below).
  let archiveSimilarAffected = 0;
  let archiveSimilarMode: "apply" | "clear" | null = null;

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const upsertResult = await rpcUser(trx, "upsert_thread", {
      user_id: userId,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Auto-archive rule fan-out: when the client set the broom flag to the
    // thread's own id (rule established) OR explicitly cleared it (rule
    // revoked), drive the matching SQL function. Idempotent on the server
    // side, so re-sends are safe.
    if (archiveSimilarSent && upsertResult) {
      const seedSelf = upsertResult.id as string;
      if (archiveSimilarValue && archiveSimilarValue === seedSelf) {
        archiveSimilarMode = "apply";
        const applied = await sql<{ apply_auto_archive: number }>`
          SELECT "user".apply_auto_archive(
            ${sql.val(userId)}::uuid,
            ${sql.val(seedSelf)}::uuid
          ) AS apply_auto_archive
        `.execute(trx);
        archiveSimilarAffected =
          applied.rows[0]?.apply_auto_archive ?? 0;
      } else if (
        archiveSimilarValue === null &&
        archiveSimilarPrevSeed !== null
      ) {
        archiveSimilarMode = "clear";
        const cleared = await sql<{ clear_auto_archive: number }>`
          SELECT "user".clear_auto_archive(
            ${sql.val(userId)}::uuid,
            ${sql.val(archiveSimilarPrevSeed)}::uuid
          ) AS clear_auto_archive
        `.execute(trx);
        archiveSimilarAffected =
          cleared.rows[0]?.clear_auto_archive ?? 0;
      }
    }

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

        // "Archive threads like this": after classification settles, check
        // whether the newly synced thread matches any of the user's active
        // auto-archive rules. The SQL function no-ops on threads already
        // archived/flagged, so re-runs are safe.
        try {
          const auto = await sql<{ apply_auto_archive_for_new_thread: string | null }>`
            SELECT "user".apply_auto_archive_for_new_thread(
              ${sql.val(userId)}::uuid,
              ${sql.val(upsertResult.id)}::uuid
            ) AS apply_auto_archive_for_new_thread
          `.execute(trx);
          const matchedSeed = auto.rows[0]?.apply_auto_archive_for_new_thread;
          if (matchedSeed) {
            c.var.tracker.capture("archive_similar_threads_match", {
              seed_thread_id: matchedSeed,
              new_thread_id: upsertResult.id,
            });
          }
        } catch (autoErr) {
          console.error(
            "[sync/threads] apply_auto_archive_for_new_thread failed:",
            autoErr
          );
          c.var.tracker.captureException(autoErr as Error);
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

  // Fire PostHog events for the "Archive threads like this" rule lifecycle.
  // The match-on-new-thread event is fired inline above (inside the
  // auto-classify branch) since it depends on the matched seed.
  if (archiveSimilarMode === "apply" && result) {
    c.var.tracker.capture("archive_similar_threads", {
      seed_thread_id: result.id,
      archived_count: archiveSimilarAffected,
      match_method: "channel+author+title_or_embedding",
    });
  } else if (archiveSimilarMode === "clear" && archiveSimilarPrevSeed) {
    c.var.tracker.capture("archive_similar_threads_clear", {
      seed_thread_id: archiveSimilarPrevSeed,
      unarchived_count: archiveSimilarAffected,
    });
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
    const dispatchInviteEmails = inviteEmails.slice();

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
            inviteEmails: dispatchInviteEmails,
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
