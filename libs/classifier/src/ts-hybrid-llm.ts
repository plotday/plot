import type {
  Candidate,
  ClassificationResult,
  Classifier,
  ClassifierContext,
} from "./types";
import type { LLMClient } from "./llm-client";
import { runTieBreaker } from "./ts-hybrid-tiebreaker";
import {
  contactHistoryShortcut,
  singlePriorityBypass,
  twistAuthorShortcut,
} from "./ts-hybrid-shortcuts";
import { runColdStart } from "./ts-hybrid-coldstart";
import { scoringStage, type ScoringOutcome } from "./ts-hybrid-scoring";
import {
  channelDefault,
  keyedPriority,
  priorityPrefix,
  priorityTitleOverride,
  rootFallback,
  topicTrainingSummary,
} from "./ts-hybrid-stages";
import {
  isTopicAmbiguous,
  pickTopicOutcome,
  runTopicLlm,
  scoringContradictsTopic,
} from "./ts-hybrid-topic-llm";
import { resolveBudgetLimits } from "./ts-hybrid-budget";
import {
  assertValidWeights,
  type BudgetLimits,
  type HybridParams,
} from "./ts-hybrid.defaults";

export type LlmClientFactory = (promptId: string) => LLMClient;
export type ConsumeBudgetFn = (
  userId: string,
  limits: BudgetLimits
) => boolean | Promise<boolean>;

export type MakeHybridLlmOpts = {
  params: HybridParams;
  /**
   * Build the LLM client for a given prompt template id. The runtime
   * provides KV-cached wrappers; eval wraps with a file cache. When
   * omitted, falls back to a process-local in-memory cache (test default).
   */
  llmClientFor: LlmClientFactory;
  /**
   * Per-user daily LLM budget gate. Returns true if the call is allowed.
   * Defaults to an in-memory per-process counter (test default).
   */
  consumeBudget?: ConsumeBudgetFn;
};

const defaultMonthBudget = new Map<string, { period: string; count: number }>();
const defaultDayBudget = new Map<string, { period: string; count: number }>();

/**
 * In-memory monthly-pool + daily-fallback gate (test/eval default). Mirrors
 * kvBudget: allow when `month < monthlyMax OR day < dailyMax`; on allow,
 * increment both counters.
 */
function defaultConsumeBudget(userId: string, limits: BudgetLimits): boolean {
  const now = new Date().toISOString();
  const month = now.slice(0, 7); // yyyy-mm
  const day = now.slice(0, 10); // yyyy-mm-dd
  const m = defaultMonthBudget.get(userId);
  const mCount = m && m.period === month ? m.count : 0;
  const d = defaultDayBudget.get(userId);
  const dCount = d && d.period === day ? d.count : 0;
  if (mCount >= limits.monthlyMax && dCount >= limits.dailyMax) return false;
  defaultMonthBudget.set(userId, { period: month, count: mCount + 1 });
  defaultDayBudget.set(userId, { period: day, count: dCount + 1 });
  return true;
}

export function makeHybridLlmClassifier(
  name: string,
  opts: MakeHybridLlmOpts
): Classifier {
  assertValidWeights(opts.params.weights);
  if (!opts.params.llm) {
    throw new Error(
      `makeHybridLlmClassifier: params.llm is required for "${name}"`
    );
  }

  const llm = opts.params.llm;
  const consumeBudget = opts.consumeBudget ?? defaultConsumeBudget;

  const tieBreakerPromptId = llm.tieBreaker.promptId;
  const coldStartPromptId = llm.coldStart.promptId;
  const topicAmbiguityPromptId = llm.topicAmbiguity.promptId;

  // Lazily construct per-prompt clients on first use. Each is wrapped to
  // count cache hits/misses for telemetry.
  let tieBreakerClient: ReturnType<typeof wrapWithStats> | null = null;
  let coldStartClient: ReturnType<typeof wrapWithStats> | null = null;
  let topicLlmClient: ReturnType<typeof wrapWithStats> | null = null;
  const getTieBreakerClient = () => {
    if (tieBreakerClient) return tieBreakerClient;
    tieBreakerClient = wrapWithStats(opts.llmClientFor(tieBreakerPromptId));
    return tieBreakerClient;
  };
  const getColdStartClient = () => {
    if (coldStartClient) return coldStartClient;
    coldStartClient = wrapWithStats(opts.llmClientFor(coldStartPromptId));
    return coldStartClient;
  };
  const getTopicLlmClient = () => {
    if (topicLlmClient) return topicLlmClient;
    topicLlmClient = wrapWithStats(opts.llmClientFor(topicAmbiguityPromptId));
    return topicLlmClient;
  };

  return {
    name,
    async classify(
      ctx: ClassifierContext,
      candidate: Candidate
    ): Promise<ClassificationResult> {
      const start = performance.now();
      let llmCalls = 0;
      let cacheHits = 0;
      const llmUsage = {
        liveInputTokens: 0,
        liveOutputTokens: 0,
        replayedInputTokens: 0,
        replayedOutputTokens: 0,
        unknownCalls: 0,
      };
      const observe = (client: ReturnType<typeof wrapWithStats>) => {
        llmCalls += client.stats.misses;
        cacheHits += client.stats.hits;
        client.stats.hits = 0;
        client.stats.misses = 0;
        llmUsage.liveInputTokens += client.usage.liveInputTokens;
        llmUsage.liveOutputTokens += client.usage.liveOutputTokens;
        llmUsage.replayedInputTokens += client.usage.replayedInputTokens;
        llmUsage.replayedOutputTokens += client.usage.replayedOutputTokens;
        llmUsage.unknownCalls += client.usage.unknownCalls;
        client.usage.liveInputTokens = 0;
        client.usage.liveOutputTokens = 0;
        client.usage.replayedInputTokens = 0;
        client.usage.replayedOutputTokens = 0;
        client.usage.unknownCalls = 0;
      };

      // Per-user LLM budget, resolved lazily by subscription tier the first
      // time an LLM stage wants to fire (deterministic-only classifications
      // never touch the DB for it). budgetExhausted is surfaced for
      // observability when the cascade falls back for lack of budget.
      let budgetExhausted = false;
      let budgetLimits: BudgetLimits | null = null;
      const tryConsumeBudget = async (): Promise<boolean> => {
        budgetLimits ??= await resolveBudgetLimits(ctx, llm);
        const ok = await consumeBudget(ctx.userId, budgetLimits);
        if (!ok) budgetExhausted = true;
        return ok;
      };
      // Scoring is computed at most once per classify and reused: the topic
      // stage needs it (to detect topic-vs-scoring contradiction and as the
      // ambiguous-topic fallback), and the later scoring stage reuses it.
      let scoreResult: ScoringOutcome | null = null;

      const pp = await priorityPrefix(ctx, candidate.topic);
      if (pp) return finish(pp);
      // Pre-insert callers (thread-helpers.prepareThreadForDb) classify
      // before the thread row exists, so candidate.threadId is "". The
      // keyed-priority join is only meaningful for an existing thread.
      if (candidate.threadId !== "") {
        const kp = await keyedPriority(ctx, candidate.threadId);
        if (kp) return finish(kp);
      }
      const tov = await priorityTitleOverride(
        ctx,
        candidate,
        opts.params.priorityTitleOverrideThreshold
      );
      if (tov) return finish(tov);

      if (candidate.topic !== null) {
        const summary = await topicTrainingSummary(
          ctx,
          candidate.topic,
          candidate.contacts
        );
        if (summary !== null) {
          // Always score here: needed to detect topic-vs-scoring
          // contradiction and as the fallback when an ambiguous topic can't
          // be resolved by the LLM. Reused by the later scoring stage.
          scoreResult = await scoringStage(ctx, candidate, opts.params);
          const ambiguous = isTopicAmbiguous(
            summary,
            candidate.contacts,
            scoringContradictsTopic(summary, scoreResult, opts.params.scoreThreshold)
          );

          // Ambiguous topics escalate to the LLM disambiguator (budget
          // permitting). A thin/contradicted plurality must not determinist-
          // ically win over the per-thread signal.
          let llmPriorityId: string | null = null;
          let llmRationale: unknown = null;
          if (ambiguous && llm.topicAmbiguity.enabled && (await tryConsumeBudget())) {
            const client = getTopicLlmClient();
            let r: Awaited<ReturnType<typeof runTopicLlm>>;
            try {
              r = await runTopicLlm({
                ctx,
                candidate,
                summary,
                scoring: scoreResult.explain,
                params: opts.params,
                llmClient: client,
              });
            } finally {
              observe(client);
            }
            if (r.fired && r.output.priorityId !== null) {
              llmPriorityId = r.output.priorityId;
              llmRationale = r.output.rationale;
            }
          }

          const outcome = pickTopicOutcome(
            summary,
            scoreResult,
            ambiguous,
            llmPriorityId
          );
          if (outcome) {
            return finish({
              priorityId: outcome.priorityId,
              stage: outcome.stage,
              scores:
                outcome.stage === "llm_topic_ambiguity"
                  ? {
                      rationale: llmRationale,
                      topic: candidate.topic,
                      candidateCount: summary.perPriority.length,
                    }
                  : outcome.stage === "scoring"
                    ? (scoreResult.explain as unknown as Record<string, unknown>)
                    : {
                        topic: candidate.topic,
                        candidateCount: summary.perPriority.length,
                      },
            });
          }
          // Ambiguous topic with no LLM resolution and no confident scoring:
          // fall through to the rest of the cascade (channel_default →
          // scoring(reused) → shortcuts → cold-start → root).
        }
      }

      const cd = await channelDefault(ctx, candidate.topic);
      if (cd) {
        if (llm.topicAmbiguity.enabled && (await tryConsumeBudget())) {
          const cdScore = await scoringStage(ctx, candidate, opts.params);
          const fakeSummary = {
            topPriorityId: cd.priorityId,
            perPriority: [
              {
                priorityId: cd.priorityId,
                n: 1,
                overlapsCandidateContacts: false,
                exemplarTitles: [],
              },
            ],
            anyContactOverlap: false,
          };
          const client = getTopicLlmClient();
          let r: Awaited<ReturnType<typeof runTopicLlm>>;
          try {
            r = await runTopicLlm({
              ctx,
              candidate,
              summary: fakeSummary,
              scoring: cdScore.explain,
              params: opts.params,
              llmClient: client,
            });
          } finally {
            observe(client);
          }
          if (r.fired && r.output.priorityId !== null) {
            return finish({
              priorityId: r.output.priorityId,
              stage: "llm_channel_default",
              scores: {
                rationale: r.output.rationale,
                channelDefault: cd.priorityId,
                channelTopic: candidate.topic,
              },
            });
          }
        }
        return finish(cd);
      }

      const score = scoreResult ?? (await scoringStage(ctx, candidate, opts.params));

      if (score.matched) {
        if (llm.tieBreaker.enabled && (await tryConsumeBudget())) {
          const client = getTieBreakerClient();
          let tb: Awaited<ReturnType<typeof runTieBreaker>>;
          try {
            tb = await runTieBreaker({
              ctx,
              candidate,
              scoring: score,
              params: opts.params,
              llmClient: client,
            });
          } finally {
            observe(client);
          }
          if (tb.fired && tb.output.priorityId !== null) {
            return finish({
              priorityId: tb.output.priorityId,
              stage: "llm_tiebreaker",
              scores: {
                rationale: tb.output.rationale,
                scoring: score.explain as unknown as Record<string, unknown>,
              },
            });
          }
        }
        return finish({
          priorityId: score.priorityId,
          stage: "scoring",
          scores: score.explain as unknown as Record<string, unknown>,
        });
      }

      const ts1 = await twistAuthorShortcut(ctx, candidate, opts.params);
      if (ts1) return finish(ts1);
      const ts2 = await contactHistoryShortcut(ctx, candidate, opts.params);
      if (ts2) return finish(ts2);
      const ts3 = await singlePriorityBypass(ctx, opts.params);
      if (ts3) return finish(ts3);

      if (llm.coldStart.enabled && (await tryConsumeBudget())) {
        const client = getColdStartClient();
        let cs: Awaited<ReturnType<typeof runColdStart>>;
        try {
          cs = await runColdStart({
            ctx,
            candidate,
            params: opts.params,
            llmClient: client,
          });
        } finally {
          observe(client);
        }
        if (cs.fired && cs.output.priorityId !== null) {
          return finish({
            priorityId: cs.output.priorityId,
            stage: "llm_coldstart",
            scores: {
              rationale: cs.output.rationale,
              considered: cs.consideredPriorityCount,
            },
          });
        }
      }

      const rf = await rootFallback(ctx);
      if (rf)
        return finish({
          priorityId: rf.priorityId,
          stage: "root_fallback",
          scores: rf.scores,
        });
      return finish({ priorityId: null, stage: "none", scores: {} });

      function finish(r: {
        priorityId: string | null;
        stage: string;
        scores: Record<string, unknown>;
      }): ClassificationResult {
        return {
          priorityId: r.priorityId,
          stage: r.stage,
          scores: r.scores,
          durationMs: performance.now() - start,
          llmCalls,
          cacheHits,
          budgetExhausted,
          llmUsage,
        };
      }
    },
  };
}

function wrapWithStats(client: LLMClient): LLMClient & {
  stats: { hits: number; misses: number };
  usage: {
    liveInputTokens: number;
    liveOutputTokens: number;
    replayedInputTokens: number;
    replayedOutputTokens: number;
    unknownCalls: number;
  };
} {
  const stats = { hits: 0, misses: 0 };
  const usage = {
    liveInputTokens: 0,
    liveOutputTokens: 0,
    replayedInputTokens: 0,
    replayedOutputTokens: 0,
    unknownCalls: 0,
  };
  const inner = client as LLMClient & {
    stats?: { hits: number; misses: number };
  };
  return {
    id: client.id,
    stats,
    usage,
    async classify(inputs) {
      const before = inner.stats ? { ...inner.stats } : null;
      const out = await client.classify(inputs);
      if (before && inner.stats) {
        stats.hits += inner.stats.hits - before.hits;
        stats.misses += inner.stats.misses - before.misses;
      } else if (out.fromCache) {
        stats.hits++;
      } else {
        stats.misses++;
      }
      // Token accounting: cache replays land in the replayed buckets, live
      // provider calls in the live buckets; calls with no usage data are
      // only counted (we can't price them).
      if (out.usage) {
        if (out.fromCache) {
          usage.replayedInputTokens += out.usage.inputTokens;
          usage.replayedOutputTokens += out.usage.outputTokens;
        } else {
          usage.liveInputTokens += out.usage.inputTokens;
          usage.liveOutputTokens += out.usage.outputTokens;
        }
      } else {
        usage.unknownCalls++;
      }
      return out;
    },
  };
}
