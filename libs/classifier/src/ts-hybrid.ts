import type {
  Candidate,
  ClassificationResult,
  Classifier,
  ClassifierContext,
} from "./types";
import { scoringStage } from "./ts-hybrid-scoring";
import {
  channelDefault,
  keyedPriority,
  priorityPrefix,
  priorityTitleOverride,
  roleInboxFallback,
  topicShortCircuit,
} from "./ts-hybrid-stages";
import { assertValidWeights, type HybridParams } from "./ts-hybrid.defaults";

export function makeHybridClassifier(
  name: string,
  params: HybridParams
): Classifier {
  assertValidWeights(params.weights);
  return {
    name,
    async classify(
      ctx: ClassifierContext,
      candidate: Candidate
    ): Promise<ClassificationResult> {
      const start = performance.now();

      // Order: hard signals from the topic itself (priority:KEY,
      // cross-user keyed filing) come first. Then title_override picks up
      // candidates whose title literally names a priority. Then the
      // fuzzy/mode-based stages (topic_shortcircuit, channel_default).
      // Scoring last.
      const pp = await priorityPrefix(ctx, candidate.topic);
      if (pp) return done(pp, start);

      const kp = await keyedPriority(ctx, candidate.threadId);
      if (kp) return done(kp, start);

      const tov = await priorityTitleOverride(
        ctx,
        candidate,
        params.priorityTitleOverrideThreshold
      );
      if (tov) return done(tov, start);

      const ts = await topicShortCircuit(ctx, candidate.topic);
      if (ts) return done(ts, start);

      const cd = await channelDefault(ctx, candidate.topic);
      if (cd) return done(cd, start);

      const score = await scoringStage(ctx, candidate, params);
      if (score.matched) {
        return done(
          {
            priorityId: score.priorityId,
            stage: "scoring",
            scores: score.explain as unknown as Record<string, unknown>,
          },
          start
        );
      }

      const rf = await roleInboxFallback(ctx, candidate);
      if (rf) {
        return done(
          {
            priorityId: rf.priorityId,
            stage: "role_inbox_fallback",
            scores: rf.scores,
          },
          start
        );
      }

      return {
        priorityId: null,
        stage: "none",
        scores: {},
        durationMs: performance.now() - start,
        llmCalls: 0,
        cacheHits: 0,
        budgetExhausted: false,
      };
    },
  };
}

function done(
  r: { priorityId: string; stage: string; scores: Record<string, unknown> },
  start: number
): ClassificationResult {
  return {
    priorityId: r.priorityId,
    stage: r.stage,
    scores: r.scores,
    durationMs: performance.now() - start,
    llmCalls: 0,
    cacheHits: 0,
    budgetExhausted: false,
  };
}
