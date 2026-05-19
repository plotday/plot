import type { Candidate, ClassifierContext } from "./types";
import type { HybridParams } from "./ts-hybrid.defaults";

type ShortcutHit =
  | { priorityId: string; stage: string; scores: Record<string, unknown> }
  | null;

export async function twistAuthorShortcut(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.twistAuthor.enabled) return null;
  if (candidate.author === null) return null;

  // Confirm the author is a twist_instance. The eval sandbox doesn't model
  // this table, so the query gracefully no-ops when nothing matches.
  const isTwist = await ctx.rawQuery(
    `SELECT 1 FROM public.twist_instance WHERE id = $1::uuid LIMIT 1`,
    [candidate.author]
  );
  if (isTwist.rows.length === 0) return null;

  const res = await ctx.rawQuery(
    `SELECT tp.priority_id, COUNT(*)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND t.created_by = $2::uuid
        AND t.archived_at IS NULL
      GROUP BY tp.priority_id`,
    [ctx.userId, candidate.author]
  );
  const rows = res.rows as { priority_id: string; n: number }[];
  const total = rows.reduce((a, r) => a + r.n, 0);
  if (total < params.shortcuts.twistAuthor.minSamples) return null;
  rows.sort((a, b) => b.n - a.n);
  const top = rows[0]!;
  if (top.n / total < params.shortcuts.twistAuthor.agreement) return null;
  return {
    priorityId: top.priority_id,
    stage: "twist_author_shortcut",
    scores: { samples: total, agreement: top.n / total },
  };
}

export async function contactHistoryShortcut(
  ctx: ClassifierContext,
  candidate: Candidate,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.contactHistory.enabled) return null;
  if (candidate.contacts.length === 0) return null;
  const res = await ctx.rawQuery(
    `SELECT DISTINCT tp.priority_id, COUNT(*)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1::uuid
        AND t.archived_at IS NULL
        AND t.contacts && $2::uuid[]
      GROUP BY tp.priority_id`,
    [ctx.userId, candidate.contacts]
  );
  const rows = res.rows as { priority_id: string; n: number }[];
  if (rows.length !== 1) return null;
  if (rows[0]!.n < params.shortcuts.contactHistory.minSamples) return null;
  return {
    priorityId: rows[0]!.priority_id,
    stage: "contact_history_shortcut",
    scores: { samples: rows[0]!.n },
  };
}

export async function singlePriorityBypass(
  ctx: ClassifierContext,
  params: HybridParams
): Promise<ShortcutHit> {
  if (!params.shortcuts.singlePriorityBypass.enabled) return null;
  const res = await ctx.rawQuery(
    `SELECT id, path::text AS path
       FROM public.priority
      WHERE user_id = $1::uuid
        AND archived_at IS NULL
      ORDER BY nlevel(path), created_at`,
    [ctx.userId]
  );
  const rows = res.rows as { id: string; path: string }[];
  if (rows.length === 0) return null;
  if (rows.length > 2) return null;
  return {
    priorityId: rows[rows.length - 1]!.id,
    stage: "single_priority_bypass",
    scores: { priorityCount: rows.length },
  };
}
