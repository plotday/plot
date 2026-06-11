import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { withDb } from "./db";
import {
  handleClassifyJob,
  type ClassifyEnv,
  type ClassifyJob,
} from "./handler";

declare const ENV: string;

export interface Env extends ClassifyEnv {
  readonly DATABASE_URL?: string;
  readonly HYPERDRIVE?: { connectionString: string };
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;
}

export default {
  async queue(unknownBatch, env, ctx) {
    const posthog = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST,
      flushAt: 5,
      flushInterval: 10,
    });
    const batch = unknownBatch as MessageBatch<ClassifyJob>;
    const logger = createLogger({
      component: "classify",
      queue: "classify-thread",
      env: typeof ENV !== "undefined" ? ENV : "unknown",
    });

    try {
      await withDb(env, async (db) => {
        for (const message of batch.messages) {
          const job = message.body;
          try {
            const outcome = await handleClassifyJob(job, env, db, (logErr) =>
              posthog.captureException(logErr as Error, job.userId, {
                threadId: job.threadId,
                context: "classification_decision_log",
              })
            );
            posthog.capture({
              distinctId: job.userId,
              event: "classify.handled",
              properties: {
                threadId: job.threadId,
                status: outcome.status,
                stage: outcome.stage,
                llmCalls: outcome.llmCalls,
                cacheHits: outcome.cacheHits,
                budgetExhausted: outcome.budgetExhausted,
                attempt: message.attempts,
              },
            });
            message.ack();
          } catch (err) {
            // Surface every consumer-throwing failure to PostHog so we
            // notice deployed bugs / chronic issues; classify_at stays
            // set so the hourly sweep re-enqueues if queue retries
            // also exhaust.
            posthog.captureException(err as Error, job.userId, {
              threadId: job.threadId,
              attempt: message.attempts,
            });
            logger.error("classify failed", err as Error, {
              userId: job.userId,
              threadId: job.threadId,
              attempt: message.attempts,
            });
            message.retry();
          }
        }
      });
    } catch (err) {
      logger.error("classify batch failure", err as Error);
      posthog.captureException(err as Error);
      // Surface a batch-wide DB connection failure to the queue runtime
      // so every message in the batch retries.
      throw err;
    } finally {
      ctx.waitUntil(posthog.shutdown());
    }
  },
} satisfies ExportedHandler<Env, ClassifyJob>;
