import type { Candidate, ClassifierContext } from "./types";
import {
  combineSignals,
  con,
  grp,
  originBonus,
  sem,
  author as authorSignal,
  priorityTitleMatch,
  titleTrigramJaccard,
  topicFuzzy,
} from "./ts-hybrid-signals";
import {
  aggregateNeighbors,
  type ScoredNeighbor,
} from "./ts-hybrid-aggregate";
import {
  detectCandidateAccounts,
  fetchAccountHierarchyAffinity,
  fetchPriorityHierarchies,
  fetchUserLinkedContacts,
  hierarchyAffinityScore,
  type AccountHierarchyAffinity,
  type PriorityHierarchy,
} from "./ts-hybrid-accounts";
import type { HybridParams } from "./ts-hybrid.defaults";

type NeighborRow = {
  priority_id: string;
  thread_id: string;
  title: string | null;
  topic: string | null;
  created_by: string | null;
  conn_id: string | null;
  contacts_expanded: string[];
  groups: string[];
  embedding: number[] | null;
};

export type ScoringExplain = {
  perPrioritySorted: {
    priorityId: string;
    score: number;
    neighborCount: number;
    /** Score from neighbor aggregation only (no title-match bonus). */
    neighborScore: number;
    /** Token-Jaccard between candidate text and priority title+path. */
    titleMatch: number;
    /** P(this priority's hierarchy | candidate's source account). 0 when
     * we have no source-account signal for the candidate. */
    accountHierarchyAffinity: number;
  }[];
  /** The hierarchy each priority lives under (depth-2 ancestor). */
  hierarchies?: Record<string, { hierarchyId: string; hierarchyTitle: string }>;
  /** Resolved source accounts for the candidate (user-linked contact ids). */
  candidateAccounts?: string[];
  topNeighbors: {
    priorityId: string;
    threadId: string;
    sem: number;
    con: number;
    grp: number;
    author: number;
    topic_fuzzy: number;
    title: number;
    origin: number;
    combined: number;
  }[];
  /** Priority IDs dropped by the facet gate before threshold checks. */
  facetGated?: string[];
};

export type ScoringOutcome =
  | {
      matched: true;
      priorityId: string;
      explain: ScoringExplain;
      top1: number;
      top2: number;
    }
  | {
      matched: false;
      explain: ScoringExplain;
      top1: number | null;
      top2: number | null;
    };

export async function scoringStage(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ScoringOutcome> {
  const res = await ctx.rawQuery(
    `SELECT tp.priority_id,
            tp.thread_id,
            mt.title,
            mt.topic,
            mt.created_by,
            CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by ELSE NULL END AS conn_id,
            public.expand_contacts(mt.contacts) AS contacts_expanded,
            mt.groups,
            CASE WHEN mt.embedding IS NULL THEN NULL ELSE mt.embedding::text END AS embedding
       FROM public.thread_priority tp
       JOIN public.thread mt ON mt.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND mt.archived_at IS NULL`,
    [ctx.userId]
  );

  const rows = (
    res.rows as Array<{
      priority_id: string;
      thread_id: string;
      title: string | null;
      topic: string | null;
      created_by: string | null;
      conn_id: string | null;
      contacts_expanded: string[];
      groups: string[];
      embedding: string | null;
    }>
  ).map<NeighborRow>((r) => ({
    priority_id: r.priority_id,
    thread_id: r.thread_id,
    title: r.title,
    topic: r.topic,
    created_by: r.created_by,
    conn_id: r.conn_id,
    contacts_expanded: r.contacts_expanded ?? [],
    groups: r.groups ?? [],
    embedding: parseEmbedding(r.embedding),
  }));

  const expandedCandidateContacts = await expandContacts(ctx, candidate.contacts);

  // Connection-origin: resolve org keys for the candidate's connection and
  // every distinct neighbor connection in one round trip. Skipped when the
  // candidate has no originating connection — origin is then 0 everywhere.
  const orgKeyByConn = new Map<string, string | null>();
  let candidateOrgKey: string | null = null;
  const originEnabled =
    (params.originBonus.exact > 0 || params.originBonus.org > 0) &&
    candidate.connectionId !== null &&
    rows.length > 0;
  if (originEnabled) {
    const connIds = new Set<string>([candidate.connectionId!]);
    for (const n of rows) if (n.conn_id) connIds.add(n.conn_id);
    const orgRes = await ctx.rawQuery(
      `SELECT conn_id, public.connection_org_key(conn_id) AS org_key
         FROM unnest($1::uuid[]) AS conn_id`,
      [[...connIds]]
    );
    for (const r of orgRes.rows as { conn_id: string; org_key: string | null }[]) {
      orgKeyByConn.set(r.conn_id, r.org_key);
    }
    candidateOrgKey = orgKeyByConn.get(candidate.connectionId!) ?? null;
  }

  // Negative examples: for each priority, the max embedding similarity between
  // the candidate and threads the user moved out of / deselected for that
  // focus (thread_priority_negative). Subtracted from the priority's score
  // below — the mirror of the user_moved positive set.
  const negByPriority = new Map<string, number>();
  if (params.negativePenaltyWeight > 0 && candidate.embedding) {
    const negRes = await ctx.rawQuery(
      `SELECT n.priority_id,
              CASE WHEN mt.embedding IS NULL THEN NULL ELSE mt.embedding::text END AS embedding
         FROM public.thread_priority_negative n
         JOIN public.thread mt ON mt.id = n.thread_id
        WHERE n.user_id = $1::uuid
          AND mt.archived_at IS NULL
          AND mt.embedding IS NOT NULL`,
      [ctx.userId]
    );
    for (const r of negRes.rows as Array<{
      priority_id: string;
      embedding: string | null;
    }>) {
      const s = sem(parseEmbedding(r.embedding), candidate.embedding);
      const prev = negByPriority.get(r.priority_id) ?? 0;
      if (s > prev) negByPriority.set(r.priority_id, s);
    }
  }

  const scored: ScoredNeighbor[] = [];
  const debugTop: ScoringExplain["topNeighbors"] = [];

  for (const n of rows) {
    const values = {
      sem: sem(n.embedding, candidate.embedding),
      con: con(n.contacts_expanded, expandedCandidateContacts),
      grp: grp(n.groups, candidate.groups),
      author: authorSignal(n.created_by, candidate.author),
      topic_fuzzy: topicFuzzy(
        n.topic,
        candidate.topic,
        params.topicFuzzyPrefixWeight
      ),
      title: titleTrigramJaccard(n.title ?? "", candidate.title),
    };
    const origin = originEnabled
      ? originBonus(
          n.conn_id,
          n.conn_id ? (orgKeyByConn.get(n.conn_id) ?? null) : null,
          candidate.connectionId,
          candidateOrgKey,
          params.originBonus
        )
      : 0;
    const combined =
      combineSignals(values, params.weights, params.nonlinearity) + origin;
    scored.push({
      priorityId: n.priority_id,
      threadId: n.thread_id,
      combined,
    });
    debugTop.push({
      priorityId: n.priority_id,
      threadId: n.thread_id,
      sem: round(values.sem),
      con: round(values.con),
      grp: round(values.grp),
      author: round(values.author),
      topic_fuzzy: round(values.topic_fuzzy),
      title: round(values.title),
      origin: round(origin),
      combined: round(combined),
    });
  }

  debugTop.sort((a, b) => b.combined - a.combined);
  const topNeighbors = debugTop.slice(0, 10);

  const neighborAggregated = aggregateNeighbors(scored, params.aggregation);
  const candidateText = `${candidate.title} ${candidate.topic ?? ""}`;

  // Priority-title bonus: include every priority with neighbors PLUS every
  // user priority whose title matches the candidate text. The latter lets
  // a clean title hit win even when no neighbor scored for that priority.
  const titleByPriority = new Map<string, number>();
  const priorityScores = new Map<
    string,
    { neighborScore: number; neighborCount: number }
  >();
  for (const p of neighborAggregated) {
    priorityScores.set(p.priorityId, {
      neighborScore: p.score,
      neighborCount: p.neighborCount,
    });
  }

  // Fetch all priorities (also needed for hierarchy lookup) and compute
  // title match across them.
  const hierarchiesById: Map<string, PriorityHierarchy> =
    params.accountHierarchyBonusWeight > 0 ||
    params.priorityTitleMatchWeight > 0
      ? await fetchPriorityHierarchies(ctx)
      : new Map();

  if (params.priorityTitleMatchWeight > 0) {
    for (const [pid, info] of hierarchiesById) {
      const tm = priorityTitleMatch(candidateText, info.title);
      titleByPriority.set(pid, tm);
      if (!priorityScores.has(pid) && tm > 0) {
        priorityScores.set(pid, { neighborScore: 0, neighborCount: 0 });
      }
    }
  }

  // Account/hierarchy affinity: build a map from candidate's source
  // accounts to their historical hierarchy distribution.
  let affinity: AccountHierarchyAffinity = new Map();
  let candidateAccounts: string[] = [];
  if (params.accountHierarchyBonusWeight > 0) {
    const linked = await fetchUserLinkedContacts(ctx);
    const linkedIds = new Set(linked.map((l) => l.id));
    candidateAccounts = detectCandidateAccounts(candidate, linkedIds);
    if (candidateAccounts.length > 0) {
      affinity = await fetchAccountHierarchyAffinity(ctx, [...linkedIds]);
      // Allow zero-neighbor priorities into the ranking when the
      // affinity signal alone gives them a non-trivial score.
      for (const [pid, info] of hierarchiesById) {
        if (priorityScores.has(pid)) continue;
        const aff = hierarchyAffinityScore(
          info.hierarchyId,
          candidateAccounts,
          affinity
        );
        if (aff > 0) priorityScores.set(pid, { neighborScore: 0, neighborCount: 0 });
      }
    }
  }

  let merged: {
    priorityId: string;
    score: number;
    neighborScore: number;
    titleMatch: number;
    accountHierarchyAffinity: number;
    neighborCount: number;
  }[] = [];
  for (const [pid, agg] of priorityScores) {
    const tm = titleByPriority.get(pid) ?? 0;
    const info = hierarchiesById.get(pid);
    const aff = info
      ? hierarchyAffinityScore(info.hierarchyId, candidateAccounts, affinity)
      : 0;
    merged.push({
      priorityId: pid,
      score:
        agg.neighborScore +
        params.priorityTitleMatchWeight * tm +
        params.accountHierarchyBonusWeight * aff -
        params.negativePenaltyWeight * (negByPriority.get(pid) ?? 0),
      neighborScore: agg.neighborScore,
      titleMatch: tm,
      accountHierarchyAffinity: aff,
      neighborCount: agg.neighborCount,
    });
  }
  merged.sort((a, b) => b.score - a.score);

  // Facet gate (mirrors classify_thread_for_user's scoring-stage gate):
  // drop ranked priorities whose facet_filters this candidate violates,
  // unless the author is trusted for that focus. Only the scoring stage is
  // gated — structural stages and cold-start are not; the LLM tie-breaker
  // inherits the gate because it draws candidates from this ranking.
  // Always evaluated when a ranking exists: trustedSendersOnly gates
  // regardless of candidate facets, and thread_facets_gated returns
  // immediately for priorities with null facet_filters.
  let facetGated: string[] = [];
  if (merged.length > 0) {
    const gateRes = await ctx.rawQuery(
      `SELECT pid, public.thread_facets_gated($1::uuid, $2::jsonb, $3::uuid, pid) AS gated
         FROM unnest($4::uuid[]) AS pid`,
      [
        ctx.userId,
        candidate.facets === null ? null : JSON.stringify(candidate.facets),
        candidate.authorContactId,
        merged.map((m) => m.priorityId),
      ]
    );
    const gatedSet = new Set(
      (gateRes.rows as { pid: string; gated: boolean }[])
        .filter((r) => r.gated)
        .map((r) => r.pid)
    );
    if (gatedSet.size > 0) {
      facetGated = merged
        .filter((m) => gatedSet.has(m.priorityId))
        .map((m) => m.priorityId);
      merged = merged.filter((m) => !gatedSet.has(m.priorityId));
    }
  }

  const hierarchiesRecord: Record<
    string,
    { hierarchyId: string; hierarchyTitle: string }
  > = {};
  for (const p of merged.slice(0, 5)) {
    const info = hierarchiesById.get(p.priorityId);
    if (info)
      hierarchiesRecord[p.priorityId] = {
        hierarchyId: info.hierarchyId,
        hierarchyTitle: info.hierarchyTitle,
      };
  }

  const explain: ScoringExplain = {
    perPrioritySorted: merged.slice(0, 5).map((p) => ({
      priorityId: p.priorityId,
      score: round(p.score),
      neighborCount: p.neighborCount,
      neighborScore: round(p.neighborScore),
      titleMatch: round(p.titleMatch),
      accountHierarchyAffinity: round(p.accountHierarchyAffinity),
    })),
    topNeighbors,
    hierarchies: hierarchiesRecord,
    candidateAccounts,
    facetGated: facetGated.length > 0 ? facetGated : undefined,
  };

  if (merged.length === 0) {
    return { matched: false, explain, top1: null, top2: null };
  }
  const top1 = merged[0]!.score;
  const top2 = merged[1]?.score ?? -Infinity;
  if (top1 < params.scoreThreshold) {
    return {
      matched: false,
      explain,
      top1,
      top2: merged[1]?.score ?? null,
    };
  }
  return {
    matched: true,
    priorityId: merged[0]!.priorityId,
    explain,
    top1,
    top2,
  };
}

async function expandContacts(
  ctx: ClassifierContext,
  contacts: string[]
): Promise<string[]> {
  if (contacts.length === 0) return [];
  const res = await ctx.rawQuery(
    `SELECT public.expand_contacts($1::uuid[]) AS expanded`,
    [contacts]
  );
  return ((res.rows[0] as { expanded: string[] | null } | undefined)?.expanded ??
    []) as string[];
}

function parseEmbedding(s: string | null): number[] | null {
  if (s === null) return null;
  const trimmed = s.replace(/^\[/, "").replace(/\]$/, "");
  if (trimmed === "") return null;
  return trimmed.split(",").map((x) => Number(x));
}

function round(x: number): number {
  return Math.round(x * 10000) / 10000;
}
