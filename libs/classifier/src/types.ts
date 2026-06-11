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
  /** Resolved created_by for the candidate thread (UUID or null). */
  author: string | null;
  /** thread.facets (format/automation/reach). Null ⇒ facet gate fails open. */
  facets: Record<string, string> | null;
  /**
   * Author contact id (thread.author_id) — the contact-level identity the
   * facet gate's trusted-sender exception checks against thread.contacts.
   * Distinct from `author` (thread.created_by: a user or twist_instance id).
   */
  authorContactId: string | null;
  /**
   * Originating connection (twist_instance id): thread.created_by when
   * thread.twist_id is set, else null. Drives the origin signal; null
   * disables it for this candidate.
   */
  connectionId: string | null;
}

export interface ClassificationResult {
  priorityId: string | null;
  stage: string;
  scores?: Record<string, unknown>;
  durationMs: number;
  /** Number of LLM calls executed during this classification (default 0). */
  llmCalls: number;
  /** Number of LLM cache hits during this classification (default 0). */
  cacheHits: number;
  /**
   * True when an LLM stage wanted to fire but the user's daily/monthly LLM
   * budget was exhausted, so the cascade fell back to a deterministic stage.
   * Surfaced for observability (PostHog) — a high rate signals the budget is
   * too low or a runaway re-classification loop. Default false.
   */
  budgetExhausted: boolean;
}

export interface Classifier {
  /** Stable identifier, e.g. "sql:current", "ts:llm:claude-sonnet-4-6". */
  name: string;
  classify(
    ctx: ClassifierContext,
    candidate: Candidate
  ): Promise<ClassificationResult>;
}
