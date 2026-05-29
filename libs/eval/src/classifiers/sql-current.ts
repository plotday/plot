import type {
  Candidate,
  ClassificationResult,
  Classifier,
  ClassifierContext,
} from "@plotday/classifier";

/**
 * Wraps the live `classify_thread_for_user_explain` SQL function in the
 * sandbox's per-run schema (search_path already set on the connection).
 */
export const sqlCurrentClassifier: Classifier = {
  name: "sql:current",

  async classify(
    ctx: ClassifierContext,
    candidate: Candidate
  ): Promise<ClassificationResult> {
    const start = performance.now();
    const result = await ctx.rawQuery(
      `SELECT priority_id, stage, scores
         FROM classify_thread_for_user_explain($1::uuid, $2::uuid)`,
      [ctx.userId, candidate.threadId]
    );
    const durationMs = performance.now() - start;
    const row = result.rows[0] as
      | { priority_id: string | null; stage: string; scores: Record<string, unknown> }
      | undefined;
    return {
      priorityId: row?.priority_id ?? null,
      stage: row?.stage ?? "none",
      scores: row?.scores ?? {},
      durationMs,
      llmCalls: 0,
      cacheHits: 0,
      budgetExhausted: false,
    };
  },
};
