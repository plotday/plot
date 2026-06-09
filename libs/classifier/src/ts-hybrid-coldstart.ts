import type { Candidate, ClassifierContext } from "./types";
import type { LLMClient, LLMOutput } from "./llm-client";
import { loadPrompt } from "./prompts";
import type { HybridParams } from "./ts-hybrid.defaults";
import {
  detectCandidateAccounts,
  fetchAccountHierarchyAffinity,
  fetchPriorityHierarchies,
  fetchUserLinkedContacts,
  labelAccount,
  renderAccountAffinityBlock,
  type PriorityHierarchy,
} from "./ts-hybrid-accounts";

export type ColdStartInputs = {
  ctx: ClassifierContext;
  candidate: Candidate;
  params: HybridParams;
  llmClient: LLMClient;
};

export type ColdStartResult =
  | { fired: false }
  | { fired: true; output: LLMOutput; consideredPriorityCount: number };

export async function runColdStart(
  inputs: ColdStartInputs
): Promise<ColdStartResult> {
  const { ctx, candidate, params, llmClient } = inputs;
  if (!params.llm?.coldStart.enabled) return { fired: false };

  const priorities = await fetchPriorityTree(ctx);
  if (priorities.length < 3) {
    // Spec §5.3: skip when fewer than two non-root priorities exist (root + 1).
    return { fired: false };
  }

  const candidatePool = truncatePriorities(
    priorities,
    candidate,
    params.llm.coldStart.maxPrioritiesInPrompt
  );
  const allowedPriorityIds = candidatePool.map((p) => p.id);

  // Account/hierarchy enrichment (for cold-start, this is often the only
  // signal we have — emphasize it).
  const linkedContacts = await fetchUserLinkedContacts(ctx);
  const linkedIds = new Set(linkedContacts.map((l) => l.id));
  const hierarchies = await fetchPriorityHierarchies(ctx);
  const affinity = await fetchAccountHierarchyAffinity(
    ctx,
    linkedContacts.map((l) => l.id)
  );
  const candidateAccounts = detectCandidateAccounts(candidate, linkedIds);

  const system = await loadPrompt(params.llm.coldStart.promptId);
  const user = renderColdStartPrompt(
    candidate,
    candidatePool,
    hierarchies,
    linkedContacts,
    affinity,
    candidateAccounts
  );
  const output = await llmClient.classify({ system, user, allowedPriorityIds });
  return { fired: true, output, consideredPriorityCount: candidatePool.length };
}

type PriorityNode = {
  id: string;
  title: string;
  path: string;
  description: string | null;
  key: string | null;
  depth: number;
};

async function fetchPriorityTree(
  ctx: ClassifierContext
): Promise<PriorityNode[]> {
  const res = await ctx.rawQuery(
    `SELECT id, title, path::text AS path, description, key, nlevel(path) AS depth
       FROM public.priority
      WHERE user_id = $1::uuid
        AND archived_at IS NULL
      ORDER BY nlevel(path), created_at`,
    [ctx.userId]
  );
  return (
    res.rows as {
      id: string;
      title: string;
      path: string;
      description: string | null;
      key: string | null;
      depth: number;
    }[]
  ).map((r) => ({ ...r, depth: Number(r.depth) }));
}

function truncatePriorities(
  priorities: PriorityNode[],
  candidate: Candidate,
  max: number
): PriorityNode[] {
  if (priorities.length <= max) return priorities;
  const candidateTokens = tokenize(
    candidate.title + " " + (candidate.topic ?? "")
  );
  const scored = priorities.map((p) => {
    const pathTokens = tokenize(p.path.replace(/\./g, " ") + " " + p.title);
    let overlap = 0;
    for (const t of candidateTokens) if (pathTokens.has(t)) overlap++;
    return { p, overlap };
  });
  const depthOne = scored.filter((s) => s.p.depth === 1).map((s) => s.p);
  const tokenMatched = scored
    .filter((s) => s.overlap > 0 && s.p.depth > 1)
    .sort((a, b) => b.overlap - a.overlap)
    .map((s) => s.p);
  const out: PriorityNode[] = [];
  const seen = new Set<string>();
  for (const p of [...depthOne, ...tokenMatched]) {
    if (seen.has(p.id)) continue;
    seen.add(p.id);
    out.push(p);
    if (out.length >= max) break;
  }
  return out;
}

function tokenize(s: string): Set<string> {
  return new Set(
    s
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 3)
  );
}

function renderColdStartPrompt(
  candidate: Candidate,
  pool: PriorityNode[],
  hierarchies: Map<string, PriorityHierarchy>,
  linkedContacts: ReturnType<typeof fetchUserLinkedContacts> extends Promise<
    infer T
  >
    ? T
    : never,
  affinity: Awaited<ReturnType<typeof fetchAccountHierarchyAffinity>>,
  candidateAccounts: string[]
): string {
  const lines: string[] = [];
  lines.push(`Candidate thread:`);
  lines.push(`  title: ${candidate.title}`);
  lines.push(`  topic: ${candidate.topic ?? "(none)"}`);
  if (candidateAccounts.length > 0) {
    const contactById = new Map(linkedContacts.map((c) => [c.id, c]));
    const labels = candidateAccounts.map((a) => {
      const c = contactById.get(a);
      return c ? labelAccount(c) : a.slice(0, 8);
    });
    lines.push(`  source account(s): ${labels.join(", ")}`);
  }
  lines.push("");
  const affinityBlock = renderAccountAffinityBlock(
    linkedContacts,
    affinity,
    hierarchies
  );
  if (affinityBlock) {
    lines.push(affinityBlock);
    lines.push("");
  }
  lines.push(`Priority tree (${pool.length} priorities):`);
  for (const p of pool) {
    const info = hierarchies.get(p.id);
    const breadcrumb = info?.breadcrumb ?? p.path.replace(/\./g, " > ");
    const hierarchy = info?.hierarchyTitle ?? "(unknown)";
    const description = info?.description ?? p.description;
    lines.push(
      `- id: ${p.id}  title: ${p.title}${description ? `  description: ${description}` : ""}  hierarchy: ${hierarchy}  path: ${breadcrumb}${p.key ? `  key: ${p.key}` : ""}`
    );
  }
  return lines.join("\n");
}
