import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { withDb } from "../db";
import { rpc } from "../rpc";
import type { Bindings } from "../env";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import { dispatchInChunks, FAN_OUT_DISPATCH } from "../utils/dispatch-chunks";

// Configuration
const STALE_THRESHOLD_MS = 60_000; // 60 seconds (increased from 30s to reduce false positives)
const ALARM_INTERVAL_MS = 30_000; // 30 seconds between recovery checks
const MAX_ALARMS_PER_CRON = 9; // 9 alarms after cron = 10 total executions per 5-minute cycle
const MAX_ITEMS_PER_QUERY = 50; // Limit per table per run

/**
 * SyncRecovery Durable Object
 *
 * Recovers missed sync notifications by periodically checking for stale
 * pending updates and notifying the appropriate sync DOs.
 *
 * Architecture:
 * - Cron trigger fires every 5 minutes, calling /trigger
 * - /trigger runs recovery and schedules 9 alarms at 30s intervals
 * - Each alarm runs recovery and schedules the next alarm
 * - After 9 alarms, stops (cron will restart the cycle)
 */
export class SyncRecovery extends DurableObject<Bindings> {
  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
  }

  /**
   * Capture exception to PostHog for monitoring
   */
  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.captureException(error, undefined, {
      durable_object: "SyncRecovery",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  async fetch(request: Request): Promise<Response> {
    const logger = createLogger({
      durable_object: "SyncRecovery",
      operation: "fetch",
    });

    try {
      const url = new URL(request.url);

      if (url.pathname === "/trigger" && request.method === "POST") {
        // Called by cron - reset alarm count and run
        await this.ctx.storage.put("alarmCount", 0);
        await this.runRecovery();
        await this.scheduleNextAlarm();
        return new Response("OK", { status: 200 });
      }

      return new Response("Not found", { status: 404 });
    } catch (error) {
      logger.error("Error in SyncRecovery fetch", error as Error);
      this.captureException(error as Error, {
        operation: "fetch",
      });
      return new Response("Internal Server Error", { status: 500 });
    }
  }

  /**
   * Called when an alarm fires
   */
  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "SyncRecovery",
      operation: "alarm",
    });

    try {
      await this.runRecovery();
    } catch (error) {
      logger.error("Error in SyncRecovery alarm", error as Error);
      this.captureException(error as Error, {
        operation: "alarm",
      });
      // Don't re-throw - we want to continue scheduling next alarm
    }

    // Schedule next alarm in separate try-catch to ensure it always runs
    try {
      await this.scheduleNextAlarm();
    } catch (error) {
      logger.error("Error scheduling next alarm", error as Error);
      this.captureException(error as Error, {
        operation: "scheduleNextAlarm",
      });
    }
  }

  /**
   * Schedule the next alarm if we haven't exceeded the limit
   */
  private async scheduleNextAlarm(): Promise<void> {
    const alarmCount = (await this.ctx.storage.get<number>("alarmCount")) || 0;

    if (alarmCount < MAX_ALARMS_PER_CRON) {
      await this.ctx.storage.put("alarmCount", alarmCount + 1);
      await this.ctx.storage.setAlarm(Date.now() + ALARM_INTERVAL_MS);
    }
    // If we've hit the limit, don't schedule - cron will restart the cycle
  }

  /**
   * Main recovery logic - finds and processes missed syncs
   */
  private async runRecovery(): Promise<void> {
    const logger = createLogger({
      durable_object: "SyncRecovery",
      operation: "runRecovery",
    });

    const startTime = Date.now();

    try {
      const staleThreshold = new Date(
        Date.now() - STALE_THRESHOLD_MS
      ).toISOString();

      // Process user syncs
      await this.recoverUserSyncs(staleThreshold, logger);

      // Process twist syncs
      await this.recoverTwistSyncs(staleThreshold, logger);

      const totalTime = Date.now() - startTime;

      // Only log if there was actual work (child methods will log details)
      if (totalTime > 100) {
        logger.info("Recovery cycle completed", {
          total_duration_ms: totalTime,
        });
      }
    } catch (error) {
      logger.error("Error in sync recovery", error as Error);
      this.captureException(error as Error, {
        operation: "runRecovery",
      });
      // Re-throw to be caught by alarm() handler
      throw error;
    }
  }

  /**
   * Find and notify stale user syncs
   */
  private async recoverUserSyncs(
    staleThreshold: string,
    logger: ReturnType<typeof createLogger>
  ): Promise<void> {
    const startTime = Date.now();

    // Use RPC to properly compare columns (last_update_at > last_sync_at)
    // and filter by stale threshold (last_sync_at < staleThreshold)
    let staleUserSyncs: Awaited<ReturnType<typeof rpc<"get_stale_user_syncs">>>;
    try {
      staleUserSyncs = await withDb(this.env, (db) =>
        rpc(db, "get_stale_user_syncs", {
          p_stale_threshold: staleThreshold,
          p_limit: MAX_ITEMS_PER_QUERY,
        })
      );
    } catch (error) {
      logger.error("Error querying stale user_sync records", error as Error);
      return;
    }

    const dbQueryTime = Date.now() - startTime;

    if (!staleUserSyncs || !Array.isArray(staleUserSyncs) || staleUserSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale user syncs", {
      count: staleUserSyncs.length,
      db_query_ms: dbQueryTime,
    });

    // Parallelize DO notifications using Promise.allSettled
    // to ensure one failure doesn't stop others
    const notifyStartTime = Date.now();
    // rpc() unwraps single-column TABLE results into raw values
    const userIds = staleUserSyncs as unknown as string[];
    // Chunked dispatch so a sweep of up to MAX_ITEMS_PER_QUERY stale syncs does
    // not schedule that many UserSync alarms in one instant (Hyperdrive pool).
    const results = await dispatchInChunks(
      userIds,
      async (userId) => {
        try {
          const userSyncId = this.env.USER_SYNC.idFromName(userId);
          const userSyncDO = this.env.USER_SYNC.get(userSyncId);
          await userSyncDO.fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ id: userId }),
            })
          );
          return { success: true, user_id: userId };
        } catch (error) {
          logger.error("Error notifying UserSync DO", error as Error, {
            user_id: userId,
          });
          return { success: false, user_id: userId, error };
        }
      },
      FAN_OUT_DISPATCH
    );
    const notifyTime = Date.now() - notifyStartTime;

    // Count successes/failures
    const successful = results.filter(
      (r) => r.status === "fulfilled" && r.value.success
    ).length;
    const failed = results.length - successful;

    logger.info("User sync recovery completed", {
      total: results.length,
      successful,
      failed,
      db_query_ms: dbQueryTime,
      notify_ms: notifyTime,
      total_ms: Date.now() - startTime,
    });
  }

  /**
   * Find and notify stale twist syncs
   */
  private async recoverTwistSyncs(
    staleThreshold: string,
    logger: ReturnType<typeof createLogger>
  ): Promise<void> {
    const startTime = Date.now();

    // Use RPC to properly compare columns (last_update_at > last_sync_at)
    // and filter by stale threshold (last_sync_at < staleThreshold)
    let staleTwistSyncs: Awaited<ReturnType<typeof rpc<"get_stale_twist_syncs">>>;
    try {
      staleTwistSyncs = await withDb(this.env, (db) =>
        rpc(db, "get_stale_twist_syncs", {
          p_stale_threshold: staleThreshold,
          p_limit: MAX_ITEMS_PER_QUERY,
        })
      );
    } catch (error) {
      logger.error("Error querying stale twist_instance_sync records", error as Error);
      return;
    }

    const dbQueryTime = Date.now() - startTime;

    if (!staleTwistSyncs || !Array.isArray(staleTwistSyncs) || staleTwistSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale twist syncs", {
      count: staleTwistSyncs.length,
      db_query_ms: dbQueryTime,
    });

    // Parallelize DO notifications using Promise.allSettled
    const notifyStartTime = Date.now();
    // rpc() unwraps single-column TABLE results into raw values
    const twistInstanceIds = staleTwistSyncs as unknown as string[];
    // Chunked dispatch so a sweep of up to MAX_ITEMS_PER_QUERY stale twist syncs
    // does not schedule that many TwistSync alarms in one instant — each alarm
    // opens a Hyperdrive connection, and the unbounded burst is what exhausted
    // the pool.
    const results = await dispatchInChunks(
      twistInstanceIds,
      async (twistInstanceId) => {
        try {
          const twistSyncId = this.env.TWIST_SYNC.idFromName(twistInstanceId);
          const twistSyncDO = this.env.TWIST_SYNC.get(twistSyncId);
          await twistSyncDO.fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ id: twistInstanceId }),
            })
          );
          return { success: true, twist_instance_id: twistInstanceId };
        } catch (error) {
          logger.error("Error notifying TwistSync DO", error as Error, {
            twist_instance_id: twistInstanceId,
          });
          return { success: false, twist_instance_id: twistInstanceId, error };
        }
      },
      FAN_OUT_DISPATCH
    );
    const notifyTime = Date.now() - notifyStartTime;

    const successful = results.filter(
      (r) => r.status === "fulfilled" && r.value.success
    ).length;
    const failed = results.length - successful;

    logger.info("Twist sync recovery completed", {
      total: results.length,
      successful,
      failed,
      db_query_ms: dbQueryTime,
      notify_ms: notifyTime,
      total_ms: Date.now() - startTime,
    });
  }
}
