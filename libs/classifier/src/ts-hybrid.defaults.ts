export type SignalWeights = {
  sem: number;
  con: number;
  grp: number;
  author: number;
  topic_fuzzy: number;
  title: number;
};

export type Nonlinearity = "identity" | "square" | "sigmoid";

export type AggregationMode =
  | { mode: "top1" }
  | { mode: "topk_mean"; k: number }
  | { mode: "softmax"; temperature: number };

export type LlmParams = {
  model:
    | "gemini-3-flash-preview"
    | "gemini-3.1-flash-lite"
    | "gemini-2.5-flash"
    | "off";
  tieBreaker: { enabled: boolean; maxCandidates: number; promptId: string };
  coldStart: { enabled: boolean; maxPrioritiesInPrompt: number; promptId: string };
  /**
   * Topic-aware override stage. Fires when topic_shortcircuit would fire
   * but the same-topic training is ambiguous (multiple priorities, or the
   * candidate's contacts don't overlap with any same-topic thread). The
   * LLM picks among the same-topic candidates and a few top-scoring
   * fallbacks. Set enabled=false to disable.
   */
  topicAmbiguity: {
    enabled: boolean;
    maxTopicCandidates: number;
    maxScoringCandidates: number;
    promptId: string;
  };
  dailyBudgetPerUser: number;
  /** Subdirectory of libs/eval/.cache/llm/ where cached responses live. */
  cacheNamespace: string;
};

export type HybridParams = {
  weights: SignalWeights;
  /** Multiplier (α_prefix in spec §4.1) for shared leading colon-segment. */
  topicFuzzyPrefixWeight: number;
  nonlinearity: Nonlinearity;
  aggregation: AggregationMode;
  scoreThreshold: number;
  /**
   * Post-aggregation bonus: for each priority, add this weight times the
   * token-level Jaccard of (candidate title + topic) and (priority title +
   * path segments). Captures cases like "File personal taxes" → Finances
   * where the candidate's text obviously names the target priority, even
   * though contact-driven neighbor scoring picks a different one. Set to 0
   * to disable.
   */
  priorityTitleMatchWeight: number;
  /**
   * When the candidate text has a token-Jaccard ≥ this threshold against
   * some priority's title, that priority's match is treated as a strong
   * intent signal that overrides earlier deterministic cascade winners
   * (topic_shortcircuit, channel_default). Set to a high value or 1.1 to
   * disable.
   */
  priorityTitleOverrideThreshold: number;
  /**
   * Post-aggregation bonus: for each priority, add this weight times
   * P(priority's hierarchy | candidate's source account). Source accounts
   * are the user's linked contacts (kris@plot.day, kbraun@talentlift.ca,
   * kris.braun@gmail.com, …) that appear in candidate.author or
   * candidate.contacts. Captures the strong "thread from this account
   * almost certainly belongs in this hierarchy" signal. Set to 0 to
   * disable.
   */
  accountHierarchyBonusWeight: number;

  highConfidenceFloor: number;
  marginFloor: number;
  nSupportingNeighbors: number;
  supportingFloor: number;

  shortcuts: {
    twistAuthor: { enabled: boolean; minSamples: number; agreement: number };
    contactHistory: { enabled: boolean; minSamples: number };
    singlePriorityBypass: { enabled: boolean };
  };

  llm?: LlmParams;
};

export const DEFAULTS: HybridParams = {
  weights: {
    sem: 0.4,
    con: 0.25,
    grp: 0.1,
    author: 0.1,
    topic_fuzzy: 0.1,
    title: 0.05,
  },
  topicFuzzyPrefixWeight: 0.6,
  nonlinearity: "square",
  aggregation: { mode: "topk_mean", k: 3 },
  // 0.08 instead of SQL's 0.15 because aggregation divides by k always
  // (so a single strong neighbor at combined=0.25 scores 0.083, not 0.25).
  scoreThreshold: 0.08,
  priorityTitleMatchWeight: 0.15,
  // 0.4 chosen empirically: gives the same gold accuracy as 0.5 on kris but
  // leaves a small safety margin against borderline false positives.
  priorityTitleOverrideThreshold: 0.4,
  // 0.20: P(hierarchy | account) for a strong-affinity case (e.g. Plot
  // account → Plot hierarchy with 67% of historical filings) contributes
  // 0.13 to the final score — meaningful but not dominating.
  accountHierarchyBonusWeight: 0.2,

  // Calibrated for the post-/k aggregation: scoring scores cluster in
  // [0.10, 0.30] on noisy real corpora. The first-round (hcf=0.30,
  // mf=0.05) only fired 5/30 scoring cases — far too conservative when
  // the LLM is hitting 75% gold on the cases it does see vs deterministic
  // scoring's 32%. Bumped wide so virtually every scoring match goes to
  // the LLM as a sanity check. The supporting-floor stays low to keep
  // catching lone-wolf-neighbor wins.
  highConfidenceFloor: 0.6,
  marginFloor: 0.2,
  nSupportingNeighbors: 2,
  supportingFloor: 0.15,

  shortcuts: {
    twistAuthor: { enabled: true, minSamples: 3, agreement: 0.8 },
    contactHistory: { enabled: true, minSamples: 2 },
    singlePriorityBypass: { enabled: true },
  },
};

export const DEFAULTS_LLM: HybridParams = {
  ...DEFAULTS,
  llm: {
    model: "gemini-3-flash-preview",
    // maxCandidates=5: kris cases frequently have the gold priority at
    // perPrioritySorted positions 3-5. With k=3 the tie-breaker had no way
    // to pick it; k=5 captures the realistic spread.
    tieBreaker: { enabled: true, maxCandidates: 5, promptId: "tiebreaker-v2" },
    coldStart: { enabled: true, maxPrioritiesInPrompt: 30, promptId: "coldstart-v2" },
    topicAmbiguity: {
      enabled: true,
      maxTopicCandidates: 4,
      maxScoringCandidates: 3,
      promptId: "topic-ambiguity-v2",
    },
    // 200 (up from spec's 50) so an eval pass over a single-user corpus
    // can fully exercise the LLM stages without truncating mid-run.
    // Production deployments will tune this down per ramping plan.
    dailyBudgetPerUser: 200,
    cacheNamespace: "default",
  },
};

export function assertValidWeights(w: SignalWeights): void {
  const total = w.sem + w.con + w.grp + w.author + w.topic_fuzzy + w.title;
  if (Math.abs(total - 1) > 1e-6) {
    throw new Error(
      `HybridParams.weights must sum to 1 (got ${total.toFixed(4)}). Adjust the weights so they total 1.`
    );
  }
}
