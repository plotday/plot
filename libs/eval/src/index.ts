export type {
  Corpus,
  CorpusWorld,
  CorpusCase,
  CorpusEmbedding,
} from "./corpus/schema";
export { loadCorpus } from "./corpus/load";
export type {
  Classifier,
  ClassifierContext,
  ClassificationResult,
  Candidate,
  HybridParams,
  SignalWeights,
  Nonlinearity,
  AggregationMode,
  LlmParams,
  LLMClient,
  LLMInputs,
  LLMOutput,
} from "@plotday/classifier";
export {
  DEFAULTS,
  DEFAULTS_LLM,
  makeHybridClassifier,
  makeHybridLlmClassifier,
} from "@plotday/classifier";
export type { RunResult, RunSummary } from "./runner/run";
export { runEval } from "./runner/run";
