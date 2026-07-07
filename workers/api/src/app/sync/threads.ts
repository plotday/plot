import { Hono } from "hono";

import { sql, withUserDb, createFrontendDb, withFrontendDb, type DB, type Kysely } from "../../db";
import type { Bindings } from "../../env";
import { rpc, rpcUser } from "../../rpc";
import {
  classifyThreadForUser,
  dispatchPendingForThread,
  enqueueJobs,
} from "../../state/classify-thread";
import { applyMuteForNewThread } from "../../state/mute";
import { checkAiLimit, isAiEnabled, recordAiUsage } from "../../utils/ai-limits";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../../utils/ai-provider";
import { cleanTitle } from "../../twist/tools/plot/thread";
import { titleFromContent, createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
import { summarize } from "../summary";
import {
  assembleSeqPage,
  parseReadParams,
  readSafeHorizon,
  selectChangedThreadIds,
  selectThreadIdsByActivity,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { createLogger } from "@plotday/worker-util";
import { sendInvitation } from "../invitation";
import { parseInviteAddress } from "./invite-address";
import { notifySync, notifyUserSyncByEnv } from "./notify";
import {
  dispatchContactsChangedIfNeeded,
  snapshotThreadContacts,
  type ThreadContactsSnapshot,
} from "./contacts-changed-dispatch";
import { inviteNewlyAddedContacts } from "./invite-added-contacts";
import {
  stripAnnounceContactsFromThreads,
  stripHiddenRoleContactsFromThreads,
} from "./viewer";
import {
  resolveCreateLinkContacts,
  dispatchCreateLink,
  noteActionsToAttachments,
  decideForward,
  type CreateLinkDraftPayload,
} from "./create-link-dispatch";
import { resolveForwardSource, buildFallbackContent } from "../../twist/forward";

/** Client-supplied request to create an external item via a connector. */
export type CreateLinkSpec = {
  twist_instance_id?: string;
  channel_id?: string | null;
  type?: string;
  // null for status-less link types (Gmail email and other message-style
  // connectors declare no `compose.status`); the client sends it as null.
  status?: string | null;
};

/**
 * Whether a `create_link` spec carries enough to dispatch to a connector's
 * onCreateLink.
 *
 * Only the IDENTIFIERS are required: `twist_instance_id` (which connector) and
 * `type` (which link type). `channel_id` and `status` are intentionally NOT
 * required:
 *
 * - `channel_id`: address/contacts-mode compose — link types whose
 *   `compose.targets` is `"addresses"` (Gmail email) or `"contacts"` (Slack
 *   DMs) — has no specific channel; the client sends `channel_id: null` (see
 *   `CreateTarget.toUserAction`, `isDmType ? null : …`) and the connector
 *   resolves its own channel inside onCreateLink.
 * - `status`: status-less link types (Gmail's `email` declares no
 *   `compose.status`; it's a message, not a task) send `status: null`.
 *   `CreateLinkDraft.status` is documented as nullable for exactly this case,
 *   and onCreateLink handles null. Requiring a truthy status here silently
 *   dropped every status-less compose — no link, no message, no error (the
 *   thread stayed a plain Plot thread with no email sent).
 */
export function isDispatchableCreateLink(
  spec: CreateLinkSpec | undefined,
): spec is CreateLinkSpec & { twist_instance_id: string; type: string } {
  return Boolean(spec?.twist_instance_id && spec.type);
}

/**
 * Expand any addressed groups to their member contact ids and merge them with
 * the directly-addressed contacts (deduped). Used by the create-link dispatch
 * so email-accepting connectors receive a group's members as recipients.
 *
 * Reuses the permission-gated `expand_group_contacts` RPC. A group the caller
 * can no longer address (or a missing group) RAISEs `P0001`, which is expected
 * and skipped silently; any other failure is forwarded to `onUnexpectedError`.
 * Expansion is ephemeral — callers do not write the result back to the thread.
 */
export async function expandGroupsToContactIds(
  db: Kysely<DB>,
  userId: string,
  directContactIds: string[],
  groupIds: string[],
  onUnexpectedError?: (error: unknown) => void,
): Promise<string[]> {
  const ids = new Set<string>(directContactIds);
  for (const groupId of groupIds) {
    try {
      const memberIds = (await rpc(db, "expand_group_contacts", {
        p_user_id: userId,
        p_group_id: groupId,
      })) as string[] | null;
      for (const id of memberIds ?? []) ids.add(id);
    } catch (error) {
      const code = (error as { code?: string } | null)?.code;
      if (code !== "P0001") onUnexpectedError?.(error);
    }
  }
  return [...ids];
}

/**
 * Compute the bge-small content embedding for a thread as a `halfvec` literal
 * (e.g. `"[0.1,0.2,...]"`), or `null` on any failure or empty result.
 *
 * Best-effort and ALWAYS resolves — it never throws. The POST /sync/threads
 * handler calls this BEFORE opening the `withUserDb` write transaction and
 * passes the result into `upsert_thread` (via `thread.embedding`), so the model
 * round-trip can't hold `upsert_thread`'s row locks open. Previously the call
 * lived inside the transaction; a slow or hung AI binding (or a worker reloaded
 * mid-request) left the transaction `idle in transaction` holding locks, which
 * wedged every subsequent push of that thread. A `null` result leaves the
 * thread NULL-embedded; the reconcile-embeddings sweep backfills it later.
 */
export async function computeThreadEmbedding(
  ai: Ai,
  text: string,
): Promise<string | null> {
  try {
    const response = (await ai.run("@cf/baai/bge-small-en-v1.5", {
      text,
    })) as { data: number[][] };
    const vec = response?.data?.[0];
    return vec ? JSON.stringify(vec) : null;
  } catch (error) {
    console.error("[sync/threads] Embedding generation failed:", error);
    return null;
  }
}

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

  const { rows, horizon, pageKeys } = await withUserDb(c.var.db, userId, async (trx) => {
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

      // Initial pull: fetch unread OR active non-archived threads. The feed
      // paginates the done tail reverse-chronologically by activity_at, so an
      // active thread with an old activity_at would otherwise never sync to a
      // fresh device (it's not unread and falls outside the windowed pull),
      // leaving the Doing section empty at rolled-up priorities. Pulling
      // active threads here (the unbounded initial pull) guarantees they reach
      // the device regardless of recency; ongoing state changes sync
      // incrementally. `active = true` covers both Doing and future Scheduled
      // (scheduled ⊂ active). Redacted stubs are archived by definition, so
      // this branch naturally excludes them. This is a strict superset of the
      // previous unread-only response, so older clients are unaffected.
      if (initial && archived !== true) {
        query = query.where(
          sql<boolean>`(archived_at IS NULL AND draft = false AND (unread = true OR active = true))`
        );
      } else {
        // Archived filter (only when not initial)
        if (archived === true) {
          query = query.where("archived_at", "is not", null);
        } else if (archived === false) {
          query = query.where("archived_at", "is", null);
        }
      }

      // Priority filter: exact match on the per-user filing. The flat
      // priority model has no descendants — a priority shows only what was
      // filed directly in it. priority_id is the canonical key; priority_path
      // is accepted for legacy clients.
      if (priorityId) {
        query = query.where("priority_id", "=", priorityId);
      } else if (priorityPath) {
        query = query.where(
          sql<boolean>`priority_path = ${priorityPath}::ltree`
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

    // Seq-cursor pulls fetch in two phases. The user.thread SELECT list is
    // expensive — agenda_at / activity_at each run correlated subqueries per
    // row — and Postgres evaluates it for EVERY row passing the cursor
    // filter, below the Sort/Limit, not just for the rows returned. When a
    // backlog of rows sits above the client's cursor (e.g. a connector
    // import being classified bumps the whole workspace), a single pull
    // projected tens of thousands of rows and blew the 30s statement
    // timeout, permanently wedging that client's sync. Phase 1 selects only
    // (id, seq) — the planner prunes the unused expensive columns — and
    // phase 2 projects the full row shape for at most `limit` ids.
    if (useSeqCursor) {
      const horizonValue = await readSafeHorizon(trx);
      // Phase 1: (id, seq) keys. On an INCREMENTAL pull, pre-filter to the
      // small set of threads whose view-seq could have advanced past the
      // cursor (selectChangedThreadIds — three index range scans), then
      // constrain the keys query to `id = ANY(...)`. This stops the planner
      // from scanning every one of the user's threads to compute and filter
      // the GREATEST() view-seq, which cost ~26s for the heaviest user even on
      // a 0-row poll. The candidate set is a SUPERSET; buildQuery still applies
      // the identical seq window / cursor / limit, so the resulting keys are
      // unchanged (see threads-changed-candidates.test.ts). On the INITIAL pull
      // (seq=0) every thread is a candidate, so the pre-filter only adds
      // overhead — keep the original full scan there.
      let keys: { id: string; seq: string }[];
      if (isInitialSync) {
        keys = (await buildQuery("user.thread")
          .clearSelect()
          .select(["id", "seq"])
          .execute()) as { id: string; seq: string }[];
      } else {
        const candidateIds = await selectChangedThreadIds(
          trx,
          userId,
          seqSince as string,
        );
        keys =
          candidateIds.length === 0
            ? []
            : ((await buildQuery("user.thread")
                .clearSelect()
                .select(["id", "seq"])
                .where(sql<boolean>`id = ANY(${candidateIds}::uuid[])`)
                .execute()) as { id: string; seq: string }[]);
      }
      const full =
        keys.length === 0
          ? []
          : await trx
              .selectFrom("user.thread")
              .selectAll()
              .where("user_id", "=", userId)
              .where(
                "id",
                "in",
                keys.map((k) => k.id),
              )
              .execute();
      const redacted = isInitialSync
        ? []
        : await buildQuery("user.thread_redacted").execute();
      const page = assembleSeqPage(
        keys,
        new Map(full.map((r) => [r.id as string, r])),
        redacted as any[],
        limit,
      );
      return { rows: page.rows, horizon: horizonValue, pageKeys: page.pageKeys };
    }

    // Feed pagination (sortBy=activity_at): two-phase, mirroring the seq path.
    // Phase-1 hits idx_thread_priority_user_activity for up to `limit` candidate
    // ids; phase-2 hydrates the full view for just those ids (re-applying the
    // real visibility / archive filters). Without this the planner materializes
    // the user.thread view over the user's whole corpus to sort+limit. Path-
    // scoped and initial pulls fall back to the single-phase query (no bounded
    // id list / no tp.priority_id pre-filter for ltree paths).
    let visible;
    if (!initial && sortBy === "activity_at" && !priorityPath) {
      const candidateIds = await selectThreadIdsByActivity(trx, userId, {
        priorityId,
        rangeStart,
        rangeEnd,
        sortDir,
        archived,
        limit,
      });
      visible =
        candidateIds.length === 0
          ? []
          : await buildQuery("user.thread")
              .where(sql<boolean>`id = ANY(${candidateIds}::uuid[])`)
              .execute();
    } else {
      // Legacy updated_since / custom-sort / initial paths: single query (the
      // unbounded legacy initial pull cannot two-phase — there is no limit to
      // bound the phase-2 id list).
      visible = await buildQuery("user.thread").execute();
    }

    if (isInitialSync) {
      return { rows: visible, horizon: "0", pageKeys: null };
    }

    const redacted = await buildQuery("user.thread_redacted").execute();

    // Merge and re-sort across both sets, then slice to the requested limit.
    // Each server-side query is already bounded by `limit`; the redacted set
    // is typically tiny (only rows where the user lost access since last sync).
    const merged = [...visible, ...redacted];
    merged.sort((a, b) => {
      const au = (a as any).updated_at ? (a as any).updated_at.getTime() : 0;
      const bu = (b as any).updated_at ? (b as any).updated_at.getTime() : 0;
      if (au !== bu) return au - bu;
      const aid = (a as any).id ?? "";
      const bid = (b as any).id ?? "";
      return aid < bid ? -1 : aid > bid ? 1 : 0;
    });
    const limitToApply = !initial ? limit : merged.length;
    return { rows: merged.slice(0, limitToApply), horizon: "0", pageKeys: null };
  });

  await stripAnnounceContactsFromThreads(c.var.db, userId, rows as any);

  // Hide BCC-style recipients (link types with a `hidden` contact role) from
  // viewers who aren't the recipient themselves or the user who added them, so
  // a BCC contact isn't exposed to the other recipients via the shared
  // thread.contacts / contact_meta.
  await stripHiddenRoleContactsFromThreads(c.var.db, userId, rows as any);

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
    // next_page / `more` derive from the phase-1 page keys, not the returned
    // rows: a row that vanished or re-seq'd between the two fetch phases must
    // not move the cursor past rows the client never received.
    const envelope = seqEnvelope(pageKeys ?? [], limit, horizon);
    return c.json({ ...envelope, rows: outRows } as any);
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
    ? sql<boolean>`ut.priority_id = ${priorityId}::uuid`
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
      -- Scheduled-send hold: a held note's content must not surface its
      -- thread in anyone else's search results.
      AND (send_at IS NULL OR send_at <= now() OR created_by = ${userId}::uuid)
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
  const createLinkSpec = body.create_link as CreateLinkSpec | undefined;
  const noteContent = (body.note_content as string | null | undefined) ?? null;
  // The source note id being forwarded, when this compose was started via
  // "Forward" — denormalized onto the thread POST for the same reason as
  // note_content (the composed note isn't reliably persisted yet at dispatch
  // time). Read defensively: no-op (null) until the client sends it.
  const noteFwdNoteId = (body.note_fwd_note as string | null | undefined) ?? null;
  // Client sends the composed thread's first note's file actions inline
  // (the note isn't reliably persisted yet at dispatch time — see
  // note_content above for the same reasoning). Read defensively: this is a
  // no-op (empty array) until the client actually sends `note_actions`.
  const noteAttachments = noteActionsToAttachments(body.note_actions);

  const threadData = body.thread || body;

  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  // Built-in-AI opt-out gate, memoized so the two AI sites below (title +
  // embedding) share a single lookup and threads that use neither pay nothing.
  let aiEnabledMemo: Promise<boolean> | undefined;
  const aiEnabled = () =>
    (aiEnabledMemo ??= isAiEnabled(c.var.db, c.var.user.id));

  // Generate AI title when client sends title=null with preview content
  if (
    !threadData.title &&
    threadData.preview &&
    typeof threadData.preview === "string" &&
    threadData.draft !== true
  ) {
    try {
      const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");
      // Skip AI titling entirely when the user has disabled built-in AI; the
      // fallback below derives a title from content without a model call.
      if (aiAllowed.allowed && (await aiEnabled())) {
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
  // create_link, note_content, note_actions, and note_fwd_note are
  // client→server control fields for the connector-backed create-new-item
  // flow; they are not thread columns.
  delete threadData.create_link;
  delete threadData.note_content;
  delete threadData.note_actions;
  delete threadData.note_fwd_note;

  // Translate legacy `topics` field (apiVersion < 3) to `groups` so
  // upsert_thread sees the new shape. If both are present, `groups` wins.
  if (threadData.topics !== undefined && threadData.groups === undefined) {
    threadData.groups = threadData.topics;
  }
  delete threadData.topics;

  // Carry the thread's team scope through to upsert_thread, which writes it
  // into thread.team_id on insert (immutable after — the
  // set_thread_team_and_external trigger locks it, so re-sends are safe).
  // Accept a camelCase `teamId` variant for parity with the snake_case
  // `team_id` the client store sends; if both are present, `team_id` wins.
  if (threadData.team_id === undefined && threadData.teamId !== undefined) {
    threadData.team_id = threadData.teamId;
  }
  delete threadData.teamId;

  // camelCase alias for topic_id (the topic this thread belongs to).
  if (threadData.topic_id === undefined && threadData.topicId !== undefined) {
    threadData.topic_id = threadData.topicId;
  }
  delete threadData.topicId;

  // Scheduled sending: a FUTURE send_at holds the thread shell (invisible to
  // recipients) until the release sweep clears it alongside the composing
  // note. A PAST send_at (offline authoring that flushed late) is stripped so
  // the compose takes the normal immediate path and no stale hold lingers —
  // POST /sync/notes strips the note's past send_at the same way.
  if (
    !(
      typeof threadData.send_at === "string" &&
      new Date(threadData.send_at).getTime() > Date.now()
    )
  ) {
    delete threadData.send_at;
  }
  const isHeldCompose = threadData.send_at != null;

  const userId = c.var.user.id;

  // Content embedding for focus-matching / classification. Computed HERE,
  // before the write transaction below, and passed into upsert_thread via
  // threadData.embedding so the model round-trip never holds upsert_thread's
  // row locks open (a slow/hung AI call or a worker reloaded mid-request would
  // otherwise leave the transaction `idle in transaction` holding locks, which
  // wedged this thread's sync entirely). Also reused for auto-classification.
  // Honor the built-in-AI opt-out and skip drafts; best-effort — a null leaves
  // the thread NULL-embedded for the reconciliation sweep to backfill.
  let queryEmbedding: string | undefined;
  if (!threadData.draft) {
    const textToEmbed = threadData.title || threadData.preview;
    if (textToEmbed && typeof textToEmbed === "string" && (await aiEnabled())) {
      const vec = await computeThreadEmbedding(c.env.AI, textToEmbed);
      if (vec) {
        queryEmbedding = vec;
        threadData.embedding = vec;
      }
    }
  }

  // Set when the user's explicit priority pick transitions this thread's
  // thread_priority.user_moved from FALSE to TRUE — i.e. this save is the
  // first filing signal. Used post-response to kick off retroactive
  // reclassification of the user's other threads against the new training
  // example (mirrors POST /sync/priority-moves).
  let userMovedTransitioned = false;

  // Track "Skip active for threads like this" intent the client passed in
  // this payload so we can fan out (apply rule) or revert (clear rule)
  // after the single-thread upsert completes. The flag is per-user (lives
  // on thread_priority), so we pre-read the previous value to decide what
  // to do when the client sends a null transition.
  const muteSent = Object.prototype.hasOwnProperty.call(
    threadData,
    "mute_by_thread_id"
  );
  const muteValue: string | null = muteSent
    ? (threadData.mute_by_thread_id as string | null) ?? null
    : null;
  let mutePrevSeed: string | null = null;
  if (muteSent && threadData.id) {
    const prev = await sql<{ mute_by_thread_id: string | null }>`
      SELECT mute_by_thread_id
      FROM public.thread_priority
      WHERE thread_id = ${sql.val(threadData.id)}::uuid
        AND user_id = ${sql.val(userId)}::uuid
    `.execute(c.var.db);
    mutePrevSeed = prev.rows[0]?.mute_by_thread_id ?? null;
  }

  // Count of threads the rule touched (for the PostHog event below).
  let muteAffected = 0;
  let muteMode: "apply" | "clear" | null = null;

  // Snapshot contacts before the upsert so we can dispatch onContactsChanged to
  // the owning connector if this save changes the thread's membership or a
  // contact's role. Only relevant for an existing thread whose payload touches
  // contacts/contact_meta — a brand new thread's roster is conveyed via
  // onLinkCreated instead.
  const contactsMayChange =
    !!threadData.id &&
    (threadData.contacts !== undefined || threadData.contact_meta !== undefined);
  let prevContacts: ThreadContactsSnapshot | null = null;
  if (contactsMayChange) {
    prevContacts = await snapshotThreadContacts(c.var.db, threadData.id as string);
  }
  // Whether this save set the thread's contacts at all (vs. a save that only
  // touched title/priority/etc.). Drives the "invite newly-added contacts"
  // pass below. Independent of `threadData.id`: a brand-new thread whose id the
  // server generates still provided contacts and has prevContacts === null.
  const contactsInPayload = threadData.contacts !== undefined;

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const upsertResult = await rpcUser(trx, "upsert_thread", {
      user_id: userId,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Mute rule fan-out: when the client set the broom flag to the
    // thread's own id (rule established) OR explicitly cleared it (rule
    // revoked), drive the matching SQL function. Idempotent on the server
    // side, so re-sends are safe.
    if (muteSent && upsertResult) {
      const seedSelf = upsertResult.id as string;
      if (muteValue && muteValue === seedSelf) {
        muteMode = "apply";
        const applied = await sql<{ apply_mute: number }>`
          SELECT "user".apply_mute(
            ${sql.val(userId)}::uuid,
            ${sql.val(seedSelf)}::uuid
          ) AS apply_mute
        `.execute(trx);
        muteAffected = applied.rows[0]?.apply_mute ?? 0;
      } else if (muteValue === null && mutePrevSeed !== null) {
        muteMode = "clear";
        const cleared = await sql<{ clear_mute: number }>`
          SELECT "user".clear_mute(
            ${sql.val(userId)}::uuid,
            ${sql.val(mutePrevSeed)}::uuid
          ) AS clear_mute
        `.execute(trx);
        muteAffected = cleared.rows[0]?.clear_mute ?? 0;
      }
    }

    // The content embedding was computed and written via threadData.embedding
    // (upsert_thread) BEFORE this transaction opened — deliberately, so the AI
    // round-trip never holds upsert_thread's row locks. `queryEmbedding` (outer
    // scope) carries it into auto-classification below.

    // Auto-classify: when the client signals auto_file, score the thread
    // against the user's explicitly-moved training threads via
    // classify_thread_for_user. The function reads topic/contacts/groups
    // directly from the thread row (via p_thread_id), so no extra params
    // are needed. We guard the UPDATE on user_moved = FALSE so the user's
    // own filing choice is never overwritten by an auto-classify pass.
    if (body.auto_file && !threadData.draft && upsertResult) {
      try {
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

        // "Skip active for threads like this": after classification settles,
        // check whether the newly synced thread matches any of the user's
        // active mute rules. The SQL function no-ops on threads already
        // archived/muted, so re-runs are safe.
        try {
          const matchedSeed = await applyMuteForNewThread(
            trx,
            userId,
            upsertResult.id
          );
          if (matchedSeed) {
            c.var.tracker.capture("mute_similar_threads_match", {
              seed_thread_id: matchedSeed,
              new_thread_id: upsertResult.id,
            });
          }
        } catch (autoErr) {
          console.error(
            "[sync/threads] apply_mute_for_new_thread failed:",
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

  // If this save changed the thread's contact membership or a contact's role,
  // notify the connector that owns the thread (best-effort, connector-only).
  if (prevContacts && result?.id) {
    await dispatchContactsChangedIfNeeded(c, result.id as string, prevContacts);
  }

  // Invite the non-Plot contacts the user newly added to this thread. Selecting
  // an existing contact writes a contact UUID into thread.contacts (via
  // upsert_thread), which — unlike the typed-email `invite_emails` path below —
  // never sent an invitation. The membership diff means routine saves (no new
  // contacts) invite nobody. Runs before the invite_emails block so the two
  // paths don't double-process the same contacts. Best-effort; never fails sync.
  //
  // Skip connector-backed compose (a Gmail/Slack/etc. send): those recipients
  // receive the native message, so a Plot invitation would be unwanted. Adding
  // someone to an existing thread's Plot sharing (no create_link) still invites.
  if (
    contactsInPayload &&
    result?.id &&
    !isDispatchableCreateLink(createLinkSpec)
  ) {
    try {
      await inviteNewlyAddedContacts(c.var.db, {
        threadId: result.id as string,
        prevContacts,
        inviterUserId: userId,
        mailQueue: c.env.MAIL_QUEUE,
        appRoot: c.env.APP_ROOT,
        captureException: (error, context) =>
          c.var.tracker.captureException(error, context),
      });
    } catch (error) {
      console.error(
        "[sync/threads] Added-contact invitation pass failed:",
        error,
      );
      c.var.tracker.captureException(error as Error);
    }
  }

  // Dispatch classify jobs for peer thread_priority rows the upsert
  // triggers wrote as pending (and the author's row if foreground
  // classify failed). Runs in waitUntil after the transaction commits;
  // opens its own DB handle because the request-scoped one is destroyed
  // by then.
  if (result?.id) {
    const threadId = result.id as string;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createFrontendDb(c.env);
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
          await withFrontendDb(c.env, async (db) => {
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
        contacts: JSON.stringify(inviteEmails.map((raw: string) => parseInviteAddress(raw))),
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

  // Fire PostHog events for the mute rule lifecycle. The match-on-new-thread
  // event is fired inline above (inside the auto-classify branch) since it
  // depends on the matched seed.
  if (muteMode === "apply" && result) {
    c.var.tracker.capture("mute_similar_threads", {
      seed_thread_id: result.id,
      muted_count: muteAffected,
      match_method: "channel+author+title_or_embedding",
    });
  } else if (muteMode === "clear" && mutePrevSeed) {
    c.var.tracker.capture("mute_similar_threads_clear", {
      seed_thread_id: mutePrevSeed,
      unmuted_count: muteAffected,
    });
  }

  notifySync(c, threadData.priority_id);

  // Dispatch to connector to create a new external item when the client
  // requested it. Fire-and-forget via waitUntil so the thread response
  // returns immediately — the link will appear via sync once the connector
  // responds.
  if (
    isDispatchableCreateLink(createLinkSpec) &&
    result &&
    threadData.draft !== true
  ) {
    // Snapshot thread fields needed inside waitUntil — `c.var.db` is torn
    // down once the response returns, so we spin up a fresh connection.
    const dispatchContactIds: string[] = Array.isArray(threadData.contacts)
      ? (threadData.contacts as string[])
      : [];
    const dispatchGroupIds: string[] = Array.isArray(threadData.groups)
      ? (threadData.groups as string[])
      : [];
    const dispatchTitle = threadData.title as string;
    const dispatchThreadId = result.id;
    const dispatchInviteEmails = inviteEmails.slice();
    const tracker = c.var.tracker;

    c.executionCtx.waitUntil(
      (async () => {
        const db = createFrontendDb(c.env);
        try {
          // Stash the spec so a failed send can be retried (cleared once
          // onCreateLink succeeds, in saveCreatedLink). Server-only — not in
          // user.thread, so it doesn't sync. Recipients are re-resolved from
          // thread.contacts on retry; only the parts not derivable from the
          // thread (connector, channel, type, status, typed addresses) are
          // stored. For a scheduled compose (held thread), this stash is what
          // the release sweep dispatches from.
          await db
            .updateTable("thread")
            .set({
              pending_create_link: sql`${JSON.stringify({
                twist_instance_id: createLinkSpec.twist_instance_id!,
                channel_id: createLinkSpec.channel_id ?? null,
                type: createLinkSpec.type!,
                status: createLinkSpec.status ?? null,
                invite_emails: dispatchInviteEmails,
              })}::jsonb`,
            })
            .where("id", "=", dispatchThreadId)
            .execute();

          // Scheduled compose: the external item must not be created until
          // the scheduled instant — the release sweep performs the deferred
          // dispatch from the stash above (publish-scheduled-notes.ts).
          if (isHeldCompose) {
            return;
          }

          // Resolve the thread's contacts into Actor rows for the connector,
          // excluding every contact linked to the creating user so the author
          // isn't passed as a recipient.
          const contacts = await resolveCreateLinkContacts(
            db,
            userId,
            dispatchContactIds,
            dispatchGroupIds,
            (error: unknown) => {
              console.error("[sync/threads] expand_group_contacts failed:", error);
              tracker.captureException(error as Error);
            },
          );

          const draft: CreateLinkDraftPayload = {
            channelId: createLinkSpec.channel_id!,
            type: createLinkSpec.type!,
            // null for status-less link types (Gmail email); onCreateLink
            // handles it. Never assert non-null here — that's the value that
            // gated Gmail compose out.
            status: createLinkSpec.status ?? null,
            title: dispatchTitle,
            noteContent,
            contacts,
            inviteEmails: dispatchInviteEmails,
            attachments: noteAttachments,
          };

          // Forward: when this compose was started via "Forward" of an
          // existing upstream item, decide whether the target connection can
          // rebuild it natively (same connection as the source + link type
          // supports it). Only the native branch is handled here.
          if (noteFwdNoteId) {
            const source = await resolveForwardSource(
              db,
              userId,
              noteFwdNoteId,
              createLinkSpec.twist_instance_id ?? null,
            );
            if (source) {
              const decision = decideForward(source, createLinkSpec.twist_instance_id ?? null);
              if (decision.mode === "native") {
                draft.forward = { key: decision.key };
              } else {
                // Fallback: the target connector can't rebuild the original
                // natively (different connection, or a link type/connector
                // without native forward support). Blockquote the original
                // into the outbound connector payload — this is race-free
                // because it reads the denormalized snapshot, not the note row.
                draft.noteContent = buildFallbackContent(draft.noteContent ?? "", source.snapshot);
                // Recipient snapshot (ForwardUserAction) is materialized onto
                // the note at /sync/notes ingest (has the note row + fwd_note);
                // not here (the note row isn't reliably persisted yet at
                // dispatch time — see note_content note above).
              }
            }
          }

          await dispatchCreateLink(c.env, c.executionCtx as any, db, {
            threadId: dispatchThreadId,
            twistInstanceId: createLinkSpec.twist_instance_id!,
            draft,
          });
        } catch (error) {
          console.error("[sync/threads] create_link dispatch failed:", error);
          tracker.captureException(error as Error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

export default threads;
