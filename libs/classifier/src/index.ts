export type {
  Classifier,
  ClassifierContext,
  ClassificationResult,
  Candidate,
  SandboxDb,
} from "./types";
export type {
  HybridParams,
  SignalWeights,
  Nonlinearity,
  AggregationMode,
  LlmParams,
  BudgetLimits,
} from "./ts-hybrid.defaults";
export {
  DEFAULTS,
  DEFAULTS_LLM,
  assertValidWeights,
} from "./ts-hybrid.defaults";
export { makeHybridClassifier } from "./ts-hybrid";
export {
  makeHybridLlmClassifier,
  type MakeHybridLlmOpts,
  type LlmClientFactory,
  type ConsumeBudgetFn,
} from "./ts-hybrid-llm";
export type { LLMClient, LLMInputs, LLMOutput } from "./llm-client";
export { LLMResponseSchema } from "./llm-client";
export { loadPrompt } from "./prompts/index";
export { shouldRunTieBreaker } from "./ts-hybrid-tiebreaker";
export {
  aggregateNeighbors,
  type ScoredNeighbor,
} from "./ts-hybrid-aggregate";
export {
  applyNonlinearity,
  author,
  combineSignals,
  con,
  grp,
  jaccard,
  priorityTitleMatch,
  sem,
  titleTrigramJaccard,
  tokenize,
  topicFuzzy,
} from "./ts-hybrid-signals";
