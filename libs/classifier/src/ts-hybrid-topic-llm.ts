import type { Candidate, ClassifierContext } from "./types";
import type { LLMClient, LLMOutput } from "./llm-client";
import { loadPrompt } from "./prompts";
import type { ScoringExplain, ScoringOutcome } from "./ts-hybrid-scoring";
import type { TopicTrainingSummary } from "./ts-hybrid-stages";
import type { HybridParams } from "./ts-hybrid.defaults";
import {
  detectCandidateAccounts,
  fetchAccountHierarchyAffinity,
  fetchPriorityHierarchies,
  fetchUserLinkedContacts,
  labelAccount,
  renderAccountAffinityBlock,
  type PriorityHierarchy,
  type UserLinkedContact,
} from "./ts-hybrid-accounts";

export type TopicLlmInputs = {
  ctx: ClassifierContext;
  candidate: Candidate;
  summary: TopicTrainingSummary;
  scoring: ScoringExplain | null;
  params: HybridParams;
  llmClient: LLMClient;
};

export type TopicLlmResult =
  | { fired: false }
  | { fired: true; output: LLMOutput };

/**
 * Returns true when topic_shortcircuit's deterministic mode is ambiguous
 * enough that we'd rather hand the decision to the LLM. Triggers:
 *   1) more than one priority has same-topic training (the mode is a
 *      tiebreak by count, not a definitive answer);
 *   2) the candidate has contacts but none of them appear in any
 *      same-topic training thread (the topic class is reused across
 *      contexts and contacts disagree with the mode);
 *   3) the mode priority has only one same-topic training thread
 *      (single-sample fragility — one historical filing decision
 *      shouldn't dictate every future thread with that topic);
 *   4) the scoring stage has a priority that's NOT the topic mode and
 *      is winning by neighbor signal + title match — the topic mode is
 *      contradicted by everything else we know.
 */
export function isTopicAmbiguous(
  summary: TopicTrainingSummary,
  candidateContacts: string[],
  scoringContradicts: boolean
): boolean {
  if (summary.perPriority.length > 1) return true;
  if (candidateContacts.length > 0 && !summary.anyContactOverlap) return true;
  if (summary.perPriority[0]!.n <= 1) return true;
  if (scoringContradicts) return true;
  return false;
}

/**
 * Criterion 4 of {@link isTopicAmbiguous}: does the scoring stage actively
 * contradict the topic mode? True when scoring has a confident match
 * (top1 ≥ 1.5× threshold) for a DIFFERENT priority than the topic mode.
 */
export function scoringContradictsTopic(
  summary: TopicTrainingSummary,
  scoring: ScoringOutcome,
  scoreThreshold: number
): boolean {
  return (
    scoring.matched &&
    scoring.priorityId !== summary.topPriorityId &&
    scoring.top1 >= scoreThreshold * 1.5
  );
}

/**
 * Decide the topic stage's outcome once all signals are computed (and the
 * LLM has either run or been skipped). Pure so it can be unit-tested without
 * the DB-heavy cascade.
 *
 *   - Unambiguous topic → short-circuit to the mode (all same-topic moves
 *     agree, so the plurality is a reliable signal).
 *   - Ambiguous topic, LLM resolved → use the LLM's pick.
 *   - Ambiguous topic, no LLM resolution (disabled, out of budget, or
 *     declined) → defer to per-thread scoring when it has a confident match;
 *     otherwise return null to fall through to the rest of the cascade
 *     (channel_default → scoring → shortcuts → cold-start → root).
 *
 * The ambiguous→scoring path is the core fix: a thin plurality on a coarse
 * shared topic (e.g. a connector-derived priority-id topic) must not override
 * the per-thread signal, and budget exhaustion must not dump every thread
 * into the mode.
 */
export function pickTopicOutcome(
  summary: TopicTrainingSummary,
  scoring: ScoringOutcome,
  ambiguous: boolean,
  llmPriorityId: string | null
): { priorityId: string; stage: string } | null {
  if (!ambiguous) {
    return { priorityId: summary.topPriorityId, stage: "topic_shortcircuit" };
  }
  if (llmPriorityId !== null) {
    return { priorityId: llmPriorityId, stage: "llm_topic_ambiguity" };
  }
  if (scoring.matched) {
    return { priorityId: scoring.priorityId, stage: "scoring" };
  }
  return null;
}

export async function runTopicLlm(inputs: TopicLlmInputs): Promise<TopicLlmResult> {
  const { ctx, candidate, summary, scoring, params, llmClient } = inputs;
  if (!params.llm?.topicAmbiguity?.enabled) return { fired: false };

  const topicCandidates = summary.perPriority.slice(
    0,
    params.llm.topicAmbiguity.maxTopicCandidates
  );
  const scoringCandidates =
    scoring?.perPrioritySorted.slice(
      0,
      params.llm.topicAmbiguity.maxScoringCandidates
    ) ?? [];

  const allIds = new Set<string>();
  for (const t of topicCandidates) allIds.add(t.priorityId);
  for (const s of scoringCandidates) allIds.add(s.priorityId);

  const allowedPriorityIds = [...allIds];
  const system = await loadPrompt(params.llm.topicAmbiguity.promptId);

  // Account / hierarchy enrichment
  const linkedContacts = await fetchUserLinkedContacts(ctx);
  const linkedIds = new Set(linkedContacts.map((l) => l.id));
  const hierarchies = await fetchPriorityHierarchies(ctx);
  const affinity = await fetchAccountHierarchyAffinity(
    ctx,
    linkedContacts.map((l) => l.id)
  );
  const candidateAccounts = detectCandidateAccounts(candidate, linkedIds);

  const user = renderTopicPrompt(
    candidate,
    topicCandidates,
    scoringCandidates,
    hierarchies,
    linkedContacts,
    affinity,
    candidateAccounts
  );

  const output = await llmClient.classify({ system, user, allowedPriorityIds });
  return { fired: true, output };
}

function renderTopicPrompt(
  candidate: Candidate,
  topicCandidates: TopicTrainingSummary["perPriority"],
  scoringCandidates: ScoringExplain["perPrioritySorted"],
  hierarchies: Map<string, PriorityHierarchy>,
  linkedContacts: UserLinkedContact[],
  affinity: ReturnType<() => Map<string, Map<string, number>>>,
  candidateAccounts: string[]
): string {
  const lines: string[] = [];
  lines.push("Candidate thread:");
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
  lines.push("Priorities that have prior threads on this exact topic:");
  for (const t of topicCandidates) {
    const p = hierarchies.get(t.priorityId);
    if (!p) continue;
    lines.push(`- id: ${t.priorityId}`);
    lines.push(`  title: ${p.title}`);
    if (p.description) lines.push(`  description: ${p.description}`);
    lines.push(`  path: ${p.breadcrumb}`);
    lines.push(`  hierarchy: ${p.hierarchyTitle}`);
    lines.push(`  same-topic threads filed here: ${t.n}`);
    lines.push(
      `  shares any contact with candidate: ${t.overlapsCandidateContacts ? "yes" : "no"}`
    );
    if (t.exemplarTitles.length > 0) {
      lines.push("  exemplars:");
      for (const ex of t.exemplarTitles) lines.push(`    - ${ex}`);
    }
  }
  if (scoringCandidates.length > 0) {
    lines.push("");
    lines.push(
      "Other priorities surfaced by general scoring (contact / embedding / title):"
    );
    for (const s of scoringCandidates) {
      const p = hierarchies.get(s.priorityId);
      if (!p) continue;
      lines.push(
        `- id: ${s.priorityId}  title: ${p.title}${p.description ? `  description: ${p.description}` : ""}  hierarchy: ${p.hierarchyTitle}  score: ${s.score} (n=${s.neighborCount}, titleMatch=${s.titleMatch}, accountAff=${s.accountHierarchyAffinity})`
      );
    }
  }
  return lines.join("\n");
}
