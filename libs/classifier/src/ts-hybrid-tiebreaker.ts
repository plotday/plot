import type { Candidate, ClassifierContext } from "./types";
import type { LLMClient, LLMOutput } from "./llm-client";
import { loadPrompt } from "./prompts";
import type { ScoringOutcome } from "./ts-hybrid-scoring";
import type { HybridParams } from "./ts-hybrid.defaults";
import {
  fetchAccountHierarchyAffinity,
  fetchPriorityHierarchies,
  fetchUserLinkedContacts,
  type UserLinkedContact,
} from "./ts-hybrid-accounts";

export type TieBreakerInputs = {
  ctx: ClassifierContext;
  candidate: Candidate;
  scoring: Extract<ScoringOutcome, { matched: true }>;
  params: HybridParams;
  llmClient: LLMClient;
};

export type TieBreakerResult =
  | { fired: false }
  | { fired: true; output: LLMOutput };

export function shouldRunTieBreaker(
  scoring: Extract<ScoringOutcome, { matched: true }>,
  params: HybridParams,
  supportingNeighborCount: number
): boolean {
  const inSoftBand =
    scoring.top1 >= params.scoreThreshold &&
    scoring.top1 <= params.highConfidenceFloor;
  const closeCall =
    scoring.top1 - (scoring.top2 ?? -Infinity) < params.marginFloor;
  const fewSupporting = supportingNeighborCount < params.nSupportingNeighbors;
  return (inSoftBand && closeCall) || fewSupporting;
}

export async function runTieBreaker(
  inputs: TieBreakerInputs
): Promise<TieBreakerResult> {
  const { ctx, candidate, scoring, params, llmClient } = inputs;
  if (!params.llm?.tieBreaker.enabled) return { fired: false };
  const supporting = scoring.explain.topNeighbors.filter(
    (n) =>
      n.priorityId === scoring.priorityId && n.combined >= params.supportingFloor
  ).length;
  if (!shouldRunTieBreaker(scoring, params, supporting)) {
    return { fired: false };
  }

  // Top-K by combined per-priority score.
  const topByScore = scoring.explain.perPrioritySorted.slice(
    0,
    params.llm.tieBreaker.maxCandidates
  );
  // Any priorities with a non-trivial title match that aren't already in
  // the top-K. These often catch cases where the candidate text obviously
  // names a priority but neighbor-based scoring missed it.
  const topByTitle = scoring.explain.perPrioritySorted
    .filter((p) => p.titleMatch >= 0.2)
    .slice(0, 3);
  const ids = new Set<string>();
  for (const p of [...topByScore, ...topByTitle]) ids.add(p.priorityId);
  const allowedPriorityIds = [...ids];
  if (allowedPriorityIds.length === 0) return { fired: false };

  const system = await loadPrompt(params.llm.tieBreaker.promptId);
  const user = await buildTieBreakerPrompt(
    ctx,
    candidate,
    allowedPriorityIds,
    scoring.explain.topNeighbors
  );

  const output = await llmClient.classify({ system, user, allowedPriorityIds });
  return { fired: true, output };
}

async function buildTieBreakerPrompt(
  ctx: ClassifierContext,
  candidate: Candidate,
  candidatePriorityIds: string[],
  topNeighbors: { priorityId: string; threadId: string; combined: number }[]
): Promise<string> {
  const [exemplarsByPriority, contactNames, linkedContacts, hierarchies] =
    await Promise.all([
      fetchExemplars(ctx, topNeighbors),
      fetchContactNames(ctx, candidate.contacts),
      fetchUserLinkedContacts(ctx),
      fetchPriorityHierarchies(ctx),
    ]);
  const linkedIds = new Set(linkedContacts.map((l) => l.id));
  const affinity = await fetchAccountHierarchyAffinity(
    ctx,
    linkedContacts.map((l) => l.id)
  );

  const candidateAccounts = new Set<string>();
  if (candidate.author && linkedIds.has(candidate.author))
    candidateAccounts.add(candidate.author);
  for (const c of candidate.contacts)
    if (linkedIds.has(c)) candidateAccounts.add(c);

  const lines: string[] = [];
  lines.push("Candidate thread:");
  lines.push(`  title: ${candidate.title}`);
  lines.push(`  topic: ${candidate.topic ?? "(none)"}`);
  lines.push(`  contacts: ${contactNames.join(", ") || "(none)"}`);
  if (candidateAccounts.size > 0) {
    const labels = labelAccounts([...candidateAccounts], linkedContacts);
    lines.push(`  source account(s): ${labels.join(", ")}`);
  }
  lines.push("");
  if (linkedContacts.length > 0) {
    lines.push("User accounts → hierarchy filing history:");
    for (const a of linkedContacts) {
      const dist = affinity.get(a.id);
      if (!dist || dist.size === 0) continue;
      const total = [...dist.values()].reduce((s, v) => s + v, 0);
      const parts: string[] = [];
      for (const [hid, n] of [...dist.entries()].sort((x, y) => y[1] - x[1])) {
        const hierarchy = hierarchies.get(hid);
        const title = hierarchy?.hierarchyTitle ?? hid.slice(0, 8);
        parts.push(`${title} (${n}/${total})`);
      }
      lines.push(`  - ${labelAccount(a)}: ${parts.join(", ")}`);
    }
    lines.push("");
  }
  lines.push("Candidate priorities:");
  for (const pid of candidatePriorityIds) {
    const info = hierarchies.get(pid);
    if (!info) continue;
    lines.push(`- id: ${pid}`);
    lines.push(`  title: ${info.title}`);
    lines.push(`  path: ${info.breadcrumb}`);
    lines.push(`  hierarchy: ${info.hierarchyTitle}`);
    const exemplars = (exemplarsByPriority.get(pid) ?? []).slice(0, 3);
    if (exemplars.length > 0) {
      lines.push("  exemplars:");
      for (const e of exemplars) {
        lines.push(`    - title: ${e.title ?? "(no title)"}`);
        if (e.topic) lines.push(`      topic: ${e.topic}`);
      }
    }
  }
  return lines.join("\n");
}

function labelAccount(c: UserLinkedContact): string {
  return c.email ?? c.name ?? c.id.slice(0, 8);
}

function labelAccounts(
  ids: string[],
  contacts: UserLinkedContact[]
): string[] {
  const m = new Map(contacts.map((c) => [c.id, c]));
  return ids.map((i) => {
    const c = m.get(i);
    return c ? labelAccount(c) : i.slice(0, 8);
  });
}


async function fetchExemplars(
  ctx: ClassifierContext,
  topNeighbors: { priorityId: string; threadId: string }[]
): Promise<Map<string, { title: string | null; topic: string | null }[]>> {
  const ids = [...new Set(topNeighbors.map((n) => n.threadId))];
  if (ids.length === 0) return new Map();
  const res = await ctx.rawQuery(
    `SELECT t.id, t.title, t.topic, tp.priority_id
       FROM public.thread t
       JOIN public.thread_priority tp ON tp.thread_id = t.id
      WHERE t.id = ANY($1::uuid[])
        AND tp.user_id = $2::uuid`,
    [ids, ctx.userId]
  );
  const out = new Map<
    string,
    { title: string | null; topic: string | null }[]
  >();
  for (const r of res.rows as {
    id: string;
    title: string | null;
    topic: string | null;
    priority_id: string;
  }[]) {
    const list = out.get(r.priority_id) ?? [];
    list.push({ title: r.title, topic: r.topic });
    out.set(r.priority_id, list);
  }
  return out;
}

async function fetchContactNames(
  ctx: ClassifierContext,
  contactIds: string[]
): Promise<string[]> {
  if (contactIds.length === 0) return [];
  const res = await ctx.rawQuery(
    `SELECT COALESCE(name, email, id::text) AS display
       FROM public.contact
      WHERE id = ANY($1::uuid[])`,
    [contactIds]
  );
  return (res.rows as { display: string }[]).map((r) => r.display);
}
