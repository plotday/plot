import type { Candidate, ClassifierContext } from "./types";
import { priorityTitleMatch } from "./ts-hybrid-signals";

/**
 * Facet `format` values considered "FYI-worthy": non-actionable, low-urgency
 * mail. Tunable — the single dial for FYI breadth. Excludes `message`/`chat`
 * (human collaboration → Inbox), `invoice` (pay-me), and `otp`/`confirm`
 * (actionable, surfaced by their own toast). `notification` is the first
 * member to narrow if FYI over-captures.
 */
export const FYI_FORMATS: ReadonlySet<string> = new Set([
  "promotion",
  "reading",
  "receipt",
  "notification",
]);

/** Pure: does this candidate's facet `format` qualify for FYI? Fails open on null. */
export function isFyiFormat(facets: Record<string, string> | null): boolean {
  const format = facets?.["format"];
  return format != null && FYI_FORMATS.has(format);
}

export type StageResult =
  | { priorityId: string; stage: string; scores: Record<string, unknown> }
  | null;

export type TopicTrainingSummary = {
  /** The mode priority (most-used) — what topic_shortcircuit returns. */
  topPriorityId: string;
  /** Every priority that has at least one same-topic user_moved thread. */
  perPriority: {
    priorityId: string;
    n: number;
    overlapsCandidateContacts: boolean;
    exemplarTitles: string[];
  }[];
  /** True if any same-topic thread shares a contact with the candidate. */
  anyContactOverlap: boolean;
};

/**
 * Fetch every priority that has same-topic training, with counts, contact
 * overlap with the candidate, and a couple of exemplar titles. The
 * cascade uses this to decide whether to fire topic_shortcircuit
 * deterministically, or whether to escalate to the LLM topic-override
 * stage when the signal is ambiguous.
 */
export async function topicTrainingSummary(
  ctx: ClassifierContext,
  topic: string,
  candidateContacts: string[]
): Promise<TopicTrainingSummary | null> {
  const res = await ctx.rawQuery(
    `SELECT tp.priority_id,
            COUNT(*)::int AS n,
            MAX(tp.updated_at) AS recent,
            COALESCE(BOOL_OR(mt.contacts && $3::uuid[]), FALSE) AS overlap,
            COALESCE(
              ARRAY_AGG(mt.title ORDER BY tp.updated_at DESC)
                FILTER (WHERE mt.title IS NOT NULL),
              ARRAY[]::text[]
            ) AS titles
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL
        AND mt.topic = $2
      GROUP BY tp.priority_id
      ORDER BY n DESC, recent DESC`,
    [ctx.userId, topic, candidateContacts]
  );
  const rows = res.rows as {
    priority_id: string;
    n: number;
    overlap: boolean;
    titles: (string | null)[];
  }[];
  if (rows.length === 0) return null;
  return {
    topPriorityId: rows[0]!.priority_id,
    perPriority: rows.map((r) => ({
      priorityId: r.priority_id,
      n: r.n,
      overlapsCandidateContacts: r.overlap,
      exemplarTitles: r.titles.filter((t): t is string => t !== null).slice(0, 2),
    })),
    anyContactOverlap: rows.some((r) => r.overlap),
  };
}

export async function topicShortCircuit(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null) return null;
  const summary = await topicTrainingSummary(ctx, topic, []);
  if (summary === null) return null;
  return {
    priorityId: summary.topPriorityId,
    stage: "topic_shortcircuit",
    scores: { topic, candidateCount: summary.perPriority.length },
  };
}

export async function keyedPriority(
  ctx: ClassifierContext,
  threadId: string
): Promise<StageResult> {
  const res = await ctx.rawQuery(
    `SELECT p.id AS priority_id, p.key
       FROM public.thread_priority tp
       JOIN public.priority src ON src.id = tp.priority_id
       JOIN public.priority p
         ON p.user_id = $1::uuid
        AND p.key = src.key
        AND p.archived_at IS NULL
      WHERE tp.thread_id = $2::uuid
        AND tp.user_id <> $1::uuid
        AND src.key IS NOT NULL
        AND src.archived_at IS NULL
      ORDER BY tp.created_at ASC
      LIMIT 1`,
    [ctx.userId, threadId]
  );
  const row = res.rows[0] as { priority_id: string; key: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.priority_id,
    stage: "keyed_priority",
    scores: { key: row.key },
  };
}

export async function channelDefault(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null || !topic.startsWith("channel:")) return null;
  const tail = topic.slice("channel:".length);
  if (tail === "") return null;
  const channelPk = Number(tail);
  if (!Number.isInteger(channelPk)) return null;
  const res = await ctx.rawQuery(
    `SELECT c.default_priority_id
       FROM public.channel c
       JOIN public.priority p ON p.id = c.default_priority_id
      WHERE c.id = $1::bigint
        AND c.default_priority_id IS NOT NULL
        AND p.user_id = $2::uuid
        AND p.archived_at IS NULL`,
    [channelPk, ctx.userId]
  );
  const row = res.rows[0] as { default_priority_id: string | null } | undefined;
  if (!row?.default_priority_id) return null;
  return {
    priorityId: row.default_priority_id,
    stage: "channel_default",
    scores: { channel_id: channelPk },
  };
}

export async function priorityPrefix(
  ctx: ClassifierContext,
  topic: string | null
): Promise<StageResult> {
  if (topic === null || !topic.startsWith("priority:")) return null;
  const key = topic.split(":")[1] ?? "";
  if (key === "") return null;
  const res = await ctx.rawQuery(
    `SELECT id
       FROM public.priority
      WHERE user_id = $1::uuid
        AND key = $2
        AND archived_at IS NULL
      LIMIT 1`,
    [ctx.userId, key]
  );
  const row = res.rows[0] as { id: string } | undefined;
  if (!row) return null;
  return {
    priorityId: row.id,
    stage: "priority_prefix",
    scores: { key },
  };
}

/**
 * If the candidate text has a strong token-Jaccard against some priority's
 * title (≥ overrideThreshold), short-circuit to that priority. This lets
 * candidates whose title obviously names the target priority bypass
 * channel-default and contact-driven scoring noise.
 *
 * Returns the strongest match (highest Jaccard) above threshold, or null.
 */
export async function priorityTitleOverride(
  ctx: ClassifierContext,
  candidate: Candidate,
  overrideThreshold: number
): Promise<StageResult> {
  if (overrideThreshold > 1) return null;
  // Match against title only (no topic): topic tokens like "channel" and
  // numeric IDs would dilute Jaccard for candidates whose title literally
  // names a priority.
  const candidateText = candidate.title;
  const res = await ctx.rawQuery(
    `SELECT id, title
       FROM public.priority
      WHERE user_id = $1::uuid
        AND archived_at IS NULL`,
    [ctx.userId]
  );
  const rows = res.rows as { id: string; title: string }[];
  let best: { id: string; title: string; tm: number } | null = null;
  for (const p of rows) {
    const tm = priorityTitleMatch(candidateText, p.title);
    if (tm < overrideThreshold) continue;
    if (best === null || tm > best.tm) best = { id: p.id, title: p.title, tm };
  }
  if (best === null) return null;
  return {
    priorityId: best.id,
    stage: "priority_title_override",
    scores: { titleMatch: best.tm, title: best.title },
  };
}

/**
 * No-match fallback: land the thread in a role's Inbox rather than a single
 * root. Picks the role most associated with the candidate's user-linked
 * accounts (their historical user_moved filing distribution); on a tie or no
 * signal, the user's oldest role wins. Returns that role's Inbox focus.
 */
export async function roleInboxFallback(
  ctx: ClassifierContext,
  candidate: Candidate
): Promise<StageResult> {
  const accounts = [candidate.author, ...candidate.contacts].filter(
    (x): x is string => typeof x === "string"
  );
  const res = await ctx.rawQuery(
    `WITH cand AS (
        SELECT uc.contact_id AS cid
          FROM public.user_contact uc
         WHERE uc.user_id = $1::uuid
           AND uc.linked = TRUE
           AND uc.archived_at IS NULL
           AND uc.contact_id = ANY($2::uuid[])
     ),
     affinity AS (
        SELECT p.role_id, COUNT(DISTINCT t.id) AS n
          FROM public.thread_priority tp
          JOIN public.thread t   ON t.id = tp.thread_id
          JOIN public.priority p ON p.id = tp.priority_id
         WHERE tp.user_id = $1::uuid
           AND tp.user_moved = TRUE
           AND t.archived_at IS NULL
           AND p.role_id IS NOT NULL
           AND (t.created_by IN (SELECT cid FROM cand)
                OR t.contacts && ARRAY(SELECT cid FROM cand))
         GROUP BY p.role_id
     )
     SELECT inbox.id AS priority_id, r.id AS role_id, COALESCE(a.n, 0) AS n
       FROM public.role r
       JOIN public.priority inbox
         ON inbox.role_id = r.id
        AND inbox.is_inbox
        AND inbox.archived_at IS NULL
       LEFT JOIN affinity a ON a.role_id = r.id
      WHERE r.user_id = $1::uuid
        AND r.archived_at IS NULL
      ORDER BY COALESCE(a.n, 0) DESC, r.created_at ASC
      LIMIT 1`,
    [ctx.userId, accounts]
  );
  const row = res.rows[0] as
    | { priority_id: string; role_id: string; n: number }
    | undefined;
  if (!row) return null;
  return {
    priorityId: row.priority_id,
    stage: "role_inbox_fallback",
    scores: { role_id: row.role_id, affinity: row.n },
  };
}

/**
 * FYI stage. Low-signal mail (by facet format) routes to the user's single
 * global FYI focus — beating soft scoring and the role-Inbox fallback — UNLESS
 * the sender already has a learned home in a real (non-Inbox, non-FYI) focus,
 * in which case we yield so scoring routes it there. Fails open (null) when the
 * format doesn't qualify or the user somehow has no FYI focus.
 */
export async function fyiFallback(
  ctx: ClassifierContext,
  candidate: Candidate
): Promise<StageResult> {
  if (!isFyiFormat(candidate.facets)) return null;

  // Yield to explicit user training: if the sender already has a learned home
  // in a real focus, let scoring route the thread there instead of FYI.
  if (candidate.authorContactId !== null) {
    const trained = await ctx.rawQuery(
      `SELECT public.author_has_real_focus_home($1::uuid, $2::uuid) AS trained`,
      [ctx.userId, candidate.authorContactId]
    );
    const trainedRow = trained.rows[0] as { trained: boolean } | undefined;
    if (trainedRow?.trained) return null;
  }

  // Resolve the user's single global FYI focus.
  const res = await ctx.rawQuery(
    `SELECT p.id
       FROM public.priority p
      WHERE p.user_id = $1::uuid
        AND p.is_fyi = TRUE
        AND p.archived_at IS NULL
      LIMIT 1`,
    [ctx.userId]
  );
  const fyi = res.rows[0] as { id: string } | undefined;
  if (!fyi?.id) return null;

  return {
    priorityId: fyi.id,
    stage: "fyi_fallback",
    scores: { format: candidate.facets?.["format"] ?? null },
  };
}
