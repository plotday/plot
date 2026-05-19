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
import { scoringStage } from "./ts-hybrid-scoring";
import {
  channelDefault,
  keyedPriority,
  priorityPrefix,
  priorityTitleOverride,
  rootFallback,
  topicTrainingSummary,
} from "./ts-hybrid-stages";
import { isTopicAmbiguous, runTopicLlm } from "./ts-hybrid-topic-llm";
import { assertValidWeights, type HybridParams } from "./ts-hybrid.defaults";

export type LlmClientFactory = (promptId: string) => LLMClient;
export type ConsumeBudgetFn = (
  userId: string,
  dailyMax: number
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

const defaultBudget = new Map<string, { date: string; count: number }>();

function defaultConsumeBudget(userId: string, dailyMax: number): boolean {
  const today = new Date().toISOString().slice(0, 10);
  const cur = defaultBudget.get(userId);
  if (!cur || cur.date !== today) {
    defaultBudget.set(userId, { date: today, count: 1 });
    return 1 <= dailyMax;
  }
  cur.count++;
  return cur.count <= dailyMax;
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
      const observe = (client: ReturnType<typeof wrapWithStats>) => {
        llmCalls += client.stats.misses;
        cacheHits += client.stats.hits;
        client.stats.hits = 0;
        client.stats.misses = 0;
      };

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
          const ambigScore = llm.topicAmbiguity.enabled
            ? await scoringStage(ctx, candidate, opts.params)
            : null;
          const scoringContradicts =
            ambigScore?.matched === true &&
            ambigScore.priorityId !== summary.topPriorityId &&
            ambigScore.top1 >= opts.params.scoreThreshold * 1.5;

          if (
            llm.topicAmbiguity.enabled &&
            isTopicAmbiguous(summary, candidate.contacts, scoringContradicts) &&
            (await consumeBudget(ctx.userId, llm.dailyBudgetPerUser))
          ) {
            const client = getTopicLlmClient();
            const r = await runTopicLlm({
              ctx,
              candidate,
              summary,
              scoring: ambigScore!.explain,
              params: opts.params,
              llmClient: client,
            });
            observe(client);
            if (r.fired && r.output.priorityId !== null) {
              return finish({
                priorityId: r.output.priorityId,
                stage: "llm_topic_ambiguity",
                scores: {
                  rationale: r.output.rationale,
                  topic: candidate.topic,
                  candidateCount: summary.perPriority.length,
                },
              });
            }
          }
          return finish({
            priorityId: summary.topPriorityId,
            stage: "topic_shortcircuit",
            scores: {
              topic: candidate.topic,
              candidateCount: summary.perPriority.length,
            },
          });
        }
      }

      const cd = await channelDefault(ctx, candidate.topic);
      if (cd) {
        if (
          llm.topicAmbiguity.enabled &&
          (await consumeBudget(ctx.userId, llm.dailyBudgetPerUser))
        ) {
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
          const r = await runTopicLlm({
            ctx,
            candidate,
            summary: fakeSummary,
            scoring: cdScore.explain,
            params: opts.params,
            llmClient: client,
          });
          observe(client);
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

      const score = await scoringStage(ctx, candidate, opts.params);

      if (score.matched) {
        if (
          llm.tieBreaker.enabled &&
          (await consumeBudget(ctx.userId, llm.dailyBudgetPerUser))
        ) {
          const client = getTieBreakerClient();
          const tb = await runTieBreaker({
            ctx,
            candidate,
            scoring: score,
            params: opts.params,
            llmClient: client,
          });
          observe(client);
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

      if (
        llm.coldStart.enabled &&
        (await consumeBudget(ctx.userId, llm.dailyBudgetPerUser))
      ) {
        const client = getColdStartClient();
        const cs = await runColdStart({
          ctx,
          candidate,
          params: opts.params,
          llmClient: client,
        });
        observe(client);
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
        };
      }
    },
  };
}

function wrapWithStats(client: LLMClient): LLMClient & {
  stats: { hits: number; misses: number };
} {
  const stats = { hits: 0, misses: 0 };
  const inner = client as LLMClient & {
    stats?: { hits: number; misses: number };
  };
  return {
    id: client.id,
    stats,
    async classify(inputs) {
      const before = inner.stats ? { ...inner.stats } : null;
      const out = await client.classify(inputs);
      if (before && inner.stats) {
        stats.hits += inner.stats.hits - before.hits;
        stats.misses += inner.stats.misses - before.misses;
      } else {
        stats.misses++;
      }
      return out;
    },
  };
}
