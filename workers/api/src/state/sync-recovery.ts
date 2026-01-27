import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { createLogger } from "../utils/logger";
import { disposeRpc } from "../utils/rpc";

// Configuration
const STALE_THRESHOLD_MS = 30_000; // 30 seconds
const ALARM_INTERVAL_MS = 10_000; // 10 seconds
const MAX_ALARMS_PER_CRON = 5; // 5 alarms after cron = 6 total executions per minute
const MAX_ITEMS_PER_QUERY = 50; // Limit per table per run

/**
 * SyncRecovery Durable Object
 *
 * Recovers missed sync notifications by periodically checking for stale
 * pending updates and notifying the appropriate sync DOs.
 *
 * Architecture:
 * - Cron trigger fires every minute, calling /trigger
 * - /trigger runs recovery and schedules 5 alarms at 10s intervals
 * - Each alarm runs recovery and schedules the next alarm
 * - After 5 alarms, stops (cron will restart the cycle)
 */
export class SyncRecovery extends DurableObject<Bindings> {
  private supabase: SupabaseClient;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  }

  /**
   * Capture exception to PostHog for monitoring
   */
  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
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
    const { data: staleUserSyncs, error } = await this.supabase.rpc(
      "get_stale_user_syncs",
      {
        p_stale_threshold: staleThreshold,
        p_limit: MAX_ITEMS_PER_QUERY,
      }
    );

    const dbQueryTime = Date.now() - startTime;

    if (error) {
      logger.error("Error querying stale user_sync records", error);
      return;
    }

    if (!staleUserSyncs || staleUserSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale user syncs", {
      count: staleUserSyncs.length,
      db_query_ms: dbQueryTime,
    });

    // Parallelize DO notifications using Promise.allSettled
    // to ensure one failure doesn't stop others
    const notifyStartTime = Date.now();
    const notifyPromises = staleUserSyncs.map(async (record) => {
      try {
        const userSyncId = this.env.USER_SYNC.idFromName(record.user_id);
        const userSyncDO = this.env.USER_SYNC.get(userSyncId);
        const result = await userSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: record.user_id }),
          })
        );
        disposeRpc(result);
        return { success: true, user_id: record.user_id };
      } catch (error) {
        logger.error("Error notifying UserSync DO", error as Error, {
          user_id: record.user_id,
        });
        return { success: false, user_id: record.user_id, error };
      }
    });

    const results = await Promise.allSettled(notifyPromises);
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
    const { data: staleTwistSyncs, error } = await this.supabase.rpc(
      "get_stale_twist_syncs",
      {
        p_stale_threshold: staleThreshold,
        p_limit: MAX_ITEMS_PER_QUERY,
      }
    );

    const dbQueryTime = Date.now() - startTime;

    if (error) {
      logger.error("Error querying stale priority_twist_sync records", error);
      return;
    }

    if (!staleTwistSyncs || staleTwistSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale twist syncs", {
      count: staleTwistSyncs.length,
      db_query_ms: dbQueryTime,
    });

    // Parallelize DO notifications using Promise.allSettled
    const notifyStartTime = Date.now();
    const notifyPromises = staleTwistSyncs.map(async (record) => {
      try {
        const twistSyncId = this.env.TWIST_SYNC.idFromName(
          record.priority_twist_id
        );
        const twistSyncDO = this.env.TWIST_SYNC.get(twistSyncId);
        const result = await twistSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: record.priority_twist_id }),
          })
        );
        disposeRpc(result);
        return { success: true, priority_twist_id: record.priority_twist_id };
      } catch (error) {
        logger.error("Error notifying TwistSync DO", error as Error, {
          priority_twist_id: record.priority_twist_id,
        });
        return { success: false, priority_twist_id: record.priority_twist_id, error };
      }
    });

    const results = await Promise.allSettled(notifyPromises);
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
