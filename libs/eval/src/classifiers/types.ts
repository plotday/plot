import type { Kysely } from "kysely";

export type SandboxDb = Kysely<Record<string, unknown>>;

export interface ClassifierContext {
  /** Kysely handle bound to the sandbox's per-run schema (search_path set). */
  db: SandboxDb;
  /** Bare pg.Client for `query()` calls when you need to bypass Kysely. */
  rawQuery: (text: string, values?: unknown[]) => Promise<{ rows: unknown[] }>;
  /** The eval user's id; matches world.user.id. */
  userId: string;
  /** Schema name used by the sandbox (informational; the DB handle has search_path set). */
  schemaName: string;
  /** Corpus name, for logging. */
  corpusName: string;
}

export interface Candidate {
  /** Sandbox-side thread row id (the candidate has already been inserted). */
  threadId: string;
  title: string;
  topic: string | null;
  contacts: string[];
  groups: string[];
  /** 384-dim embedding, already converted to halfvec literal in the DB row. */
  embedding: number[] | null;
}

export interface ClassificationResult {
  priorityId: string | null;
  stage: string;
  scores?: Record<string, unknown>;
  durationMs: number;
}

export interface Classifier {
  /** Stable identifier, e.g. "sql:current", "ts:llm:claude-sonnet-4-6". */
  name: string;
  classify(
    ctx: ClassifierContext,
    candidate: Candidate
  ): Promise<ClassificationResult>;
}
