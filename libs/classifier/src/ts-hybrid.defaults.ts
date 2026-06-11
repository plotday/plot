export type SignalWeights = {
  sem: number;
  con: number;
  grp: number;
  author: number;
  topic_fuzzy: number;
  title: number;
};

export type Nonlinearity = "identity" | "square" | "sigmoid";

/**
 * Per-user LLM-call budget. The monthly pool absorbs large one-time imports
 * with no daily throttle; once it is exhausted the daily cap takes over for
 * the rest of the month, so sustained heavy usage is rate-limited but never
 * fully cut off (over-budget classifications degrade to deterministic
 * scoring, not the bare topic mode). The gate allows a call when
 * `monthCount < monthlyMax OR dayCount < dailyMax`.
 */
export type BudgetLimits = {
  /** Generous monthly pool (LLM calls / calendar month, UTC). */
  monthlyMax: number;
  /** Daily trickle that applies only after the monthly pool is spent. */
  dailyMax: number;
};

export type AggregationMode =
  | { mode: "top1" }
  | { mode: "topk_mean"; k: number }
  | { mode: "softmax"; temperature: number };

export type OriginBonus = { exact: number; org: number };

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
  /**
   * Budget for paid plans (user_subscription.plan ∈ {core, pro, team} with
   * status ∈ {active, trialing}). Effectively unlimited for real use — sized
   * to absorb a very large initial import — and serves only as a bug/abuse
   * ceiling.
   */
  budgetPaid: BudgetLimits;
  /** Budget for free / lapsed users. */
  budgetFree: BudgetLimits;
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
  /**
   * Post-aggregation penalty: for each priority, subtract this weight times
   * the max embedding similarity between the candidate and that priority's
   * NEGATIVE examples — threads the user moved out of the focus, or
   * deselected when creating it (stored in thread_priority_negative). The
   * mirror image of the user_moved positive training set. Set to 0 to disable.
   */
  negativePenaltyWeight: number;
  /**
   * Per-neighbor additive bonus when a user_moved example came from the
   * SAME connection as the candidate (exact) or a connection sharing its
   * org key (org) — mirrors the SQL scorer's 0.18/0.09 origin term. Added
   * to the per-neighbor combined score BEFORE aggregation, outside the
   * normalized SignalWeights. NOTE: topk_mean divides by k, so the
   * post-aggregation effect is ~1/k of the SQL constants — these defaults
   * are a starting point, tunable once the eval corpus models
   * connections. Set both to 0 to disable.
   */
  originBonus: OriginBonus;

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
  // 0.3: a strong negative (candidate ~0.8 cosine to a moved-out/deselected
  // thread) subtracts ~0.24 — enough to demote a focus the user has rejected
  // for similar threads without overriding strong positive evidence.
  negativePenaltyWeight: 0.3,
  originBonus: { exact: 0.18, org: 0.09 },

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
    tieBreaker: { enabled: true, maxCandidates: 5, promptId: "tiebreaker-v3" },
    coldStart: { enabled: true, maxPrioritiesInPrompt: 30, promptId: "coldstart-v3" },
    topicAmbiguity: {
      enabled: true,
      maxTopicCandidates: 4,
      maxScoringCandidates: 3,
      promptId: "topic-ambiguity-v3",
    },
    // Monthly pool absorbs the initial import unthrottled; the daily cap is
    // the post-exhaustion sustained rate. Paid is effectively unlimited for
    // real use (a bug/abuse ceiling); free still classifies a moderate
    // import, then trickles. Over-budget calls degrade to scoring, not the
    // bare topic mode (see ts-hybrid-llm topic stage).
    budgetPaid: { monthlyMax: 50_000, dailyMax: 500 },
    budgetFree: { monthlyMax: 5_000, dailyMax: 100 },
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
