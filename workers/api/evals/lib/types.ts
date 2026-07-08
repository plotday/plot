export type Difficulty = "easy" | "medium" | "hard";

export interface SpecAssertion {
  match: string; // JS regex source, case-sensitive
  why: string;
}

export interface SpecNotMatch {
  pattern: string; // JS regex source, case-sensitive
  why: string;
}

export interface CorpusSpec {
  id: string;
  category: string;
  difficulty: Difficulty;
  assertions: SpecAssertion[];
  notMatch: SpecNotMatch[];
  allowDeps: string[];
  body: string; // the markdown spec a user would write
  corpusHash: string; // sha256 hex of the full file content
  filePath: string;
}

export type SpecStatus =
  | "pass"
  | "assertion_failed"
  | "typecheck_failed"
  | "generation_failed"
  | "timeout"
  | "infra";

export type FailureClass =
  | "api_error"
  | "output_truncated"
  | "schema_mismatch"
  | "build_npm_install"
  | "build_bundle"
  | "build_container_infra"
  | "max_attempts_exhausted"
  | "assertion_failed"
  | "typecheck_failed"
  | "timeout"
  | "infra";

export type BuildFailureClass =
  | "build_npm_install"
  | "build_bundle"
  | "build_container_infra";

export interface Classification {
  failureClass: FailureClass;
  finalBuildClass?: BuildFailureClass;
  detail: string; // trimmed to 500 chars
}

export interface TokenTotals {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

export interface SpecResult {
  id: string;
  category: string;
  difficulty: Difficulty;
  corpusHash: string;
  run: number; // 1-based --runs iteration
  status: SpecStatus;
  failureClass: FailureClass | null;
  finalBuildClass: BuildFailureClass | null;
  failureDetail: string | null;
  assertionFailures: string[];
  attemptsUsed: number;
  durations: { totalMs: number; llmMs: number[]; buildMs: number[] };
  tokens: TokenTotals;
  estimatedCostUsd: number;
  extraDeps: string[];
  files: string[];
}

export interface RunResults {
  schemaVersion: 1;
  startedAt: string; // ISO
  label: string;
  model: string;
  flags: { concurrency: number; runs: number; only: string | null };
  specs: SpecResult[];
  aggregates: {
    pipelinePassRate: number | null; // generation resolved / counted (infra excluded)
    fullPassRate: number | null; // all check levels passed / counted
    meanAttempts: number | null;
    latencyMs: { median: number | null; p95: number | null };
    totalCostUsd: number;
    taxonomy: Record<string, number>;
  };
}

/** Local environment/setup problem — excluded from pass-rate math. */
export class EvalInfraError extends Error {}

/** Per-spec wall-clock cap exceeded. */
export class EvalTimeoutError extends Error {
  constructor(ms: number) {
    super(`no result within ${Math.round(ms / 1000)}s`);
  }
}
