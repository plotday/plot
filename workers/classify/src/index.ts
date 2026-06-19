import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { withDb, isLockTimeoutError, isStatementTimeoutError } from "./db";
import {
  handleClassifyJob,
  parkUnclassifiable,
  type ClassifyEnv,
  type ClassifyJob,
} from "./handler";

declare const ENV: string;

// Give-up threshold. The classify-thread queue is configured with
// max_retries=4 (wrangler.jsonc), i.e. up to 5 deliveries. On the last useful
// attempt we stop retrying and PARK the thread instead (file at root + clear
// classify_at) so the hourly sweep stops re-enqueuing it. Without this, a
// thread whose scoring can't finish inside the 30s statement_timeout — or one
// wedged on sustained user_sync row-lock contention — is re-fed every hour
// forever: the retry storm (PostHog 019ed53e / 019ed55a).
const MAX_CLASSIFY_ATTEMPTS = 4;

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
            if (message.attempts >= MAX_CLASSIFY_ATTEMPTS) {
              // Retries exhausted: give up rather than loop forever. Park the
              // thread (file at root + clear classify_at) so the hourly sweep
              // stops re-enqueuing it — that re-enqueue is what turns one
              // slow/contended thread into an unbounded retry storm. Parking is
              // cheap and scoring-free, so it succeeds even when classification
              // itself can't.
              try {
                await parkUnclassifiable(db, job);
                posthog.capture({
                  distinctId: job.userId,
                  event: "classify.gave_up",
                  properties: {
                    threadId: job.threadId,
                    attempt: message.attempts,
                    pg_code: (err as { code?: string })?.code,
                  },
                });
                logger.warn(
                  "classify gave up after exhausting retries; parked at root",
                  {
                    userId: job.userId,
                    threadId: job.threadId,
                    attempt: message.attempts,
                    pg_code: (err as { code?: string })?.code,
                  }
                );
                message.ack();
              } catch (parkErr) {
                // Parking failed too (DB still overloaded). Don't silently drop
                // the job: leave classify_at set and let the queue/sweep retry.
                logger.error("classify park failed", parkErr as Error, {
                  userId: job.userId,
                  threadId: job.threadId,
                });
                message.retry();
              }
            } else if (isLockTimeoutError(err)) {
              // Expected, self-healing contention: a concurrent per-user writer
              // (reclassify_user_threads, a connector sync, or a sibling
              // settle) held the thread_priority / user_sync row lock past our
              // short lock_timeout. classify_at stays set, so the queue retry
              // and the hourly sweep re-enqueue the job to run when the lock is
              // free. Don't report it as a bug (this is the PostHog 019ed55a
              // burst). A genuinely slow statement still trips the 30s
              // statement_timeout (57014), which falls through to capture.
              logger.warn("classify settle contended on row lock; retrying", {
                userId: job.userId,
                threadId: job.threadId,
                attempt: message.attempts,
                pg_code: (err as { code?: string })?.code,
              });
              message.retry();
            } else if (isStatementTimeoutError(err)) {
              // A 30s statement_timeout (57014) with lock_timeout=5s in place
              // means the query genuinely ran 30s without lock-waiting. For
              // classify that is NOT a slow query — every scoring query is
              // <120ms warm in prod — but transient DB backend SATURATION
              // during a reclassification burst (the hourly sweep re-enqueues
              // up to 1000 of one user's pending rows, which, with queue
              // retries and that user's own traffic, overloads the backend).
              // Re-delivering immediately just piles more load onto the
              // already-overloaded backend and sustains the storm (PostHog
              // 019ed53e). So we DEFER instead of retry: ack the message to
              // stop immediate re-delivery while leaving classify_at set, so
              // the next hourly sweep re-enqueues the job once contention has
              // cleared (the query is then fast). We do NOT push classify_at
              // forward — its value gates unfiled-thread visibility via
              // classify_visibility_window(), so moving it would re-hide the
              // thread. Captured once (not once per retry) for visibility; the
              // rate falls as the storm shrinks.
              posthog.captureException(err as Error, job.userId, {
                threadId: job.threadId,
                attempt: message.attempts,
                deferred_to_sweep: true,
              });
              logger.warn(
                "classify timed out under load; deferring to hourly sweep",
                {
                  userId: job.userId,
                  threadId: job.threadId,
                  attempt: message.attempts,
                  pg_code: (err as { code?: string })?.code,
                }
              );
              message.ack();
            } else {
              // Surface every other consumer-throwing failure to PostHog so we
              // notice deployed bugs / chronic issues; classify_at stays set so
              // the queue retry re-runs it until the attempt cap above parks it.
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
