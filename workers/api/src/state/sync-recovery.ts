import { DurableObject } from "cloudflare:workers";

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

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/trigger" && request.method === "POST") {
      // Called by cron - reset alarm count and run
      await this.ctx.storage.put("alarmCount", 0);
      await this.runRecovery();
      await this.scheduleNextAlarm();
      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  /**
   * Called when an alarm fires
   */
  async alarm(): Promise<void> {
    await this.runRecovery();
    await this.scheduleNextAlarm();
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

    try {
      const staleThreshold = new Date(
        Date.now() - STALE_THRESHOLD_MS
      ).toISOString();

      // Process user syncs
      await this.recoverUserSyncs(staleThreshold, logger);

      // Process twist syncs
      await this.recoverTwistSyncs(staleThreshold, logger);
    } catch (error) {
      logger.error("Error in sync recovery", error as Error);
    }
  }

  /**
   * Find and notify stale user syncs
   */
  private async recoverUserSyncs(
    staleThreshold: string,
    logger: ReturnType<typeof createLogger>
  ): Promise<void> {
    // Use RPC to properly compare columns (last_update_at > last_sync_at)
    // and filter by stale threshold (last_sync_at < staleThreshold)
    const { data: staleUserSyncs, error } = await this.supabase.rpc(
      "get_stale_user_syncs",
      {
        p_stale_threshold: staleThreshold,
        p_limit: MAX_ITEMS_PER_QUERY,
      }
    );

    if (error) {
      logger.error("Error querying stale user_sync records", error);
      return;
    }

    if (!staleUserSyncs || staleUserSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale user syncs", {
      count: staleUserSyncs.length,
    });

    // Notify UserSync DOs
    for (const record of staleUserSyncs) {
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
      } catch (error) {
        logger.error("Error notifying UserSync DO", error as Error, {
          user_id: record.user_id,
        });
      }
    }
  }

  /**
   * Find and notify stale twist syncs
   */
  private async recoverTwistSyncs(
    staleThreshold: string,
    logger: ReturnType<typeof createLogger>
  ): Promise<void> {
    // Use RPC to properly compare columns (last_update_at > last_sync_at)
    // and filter by stale threshold (last_sync_at < staleThreshold)
    const { data: staleTwistSyncs, error } = await this.supabase.rpc(
      "get_stale_twist_syncs",
      {
        p_stale_threshold: staleThreshold,
        p_limit: MAX_ITEMS_PER_QUERY,
      }
    );

    if (error) {
      logger.error("Error querying stale priority_twist_sync records", error);
      return;
    }

    if (!staleTwistSyncs || staleTwistSyncs.length === 0) {
      return;
    }

    logger.info("Recovering stale twist syncs", {
      count: staleTwistSyncs.length,
    });

    // Notify TwistSync DOs
    for (const record of staleTwistSyncs) {
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
      } catch (error) {
        logger.error("Error notifying TwistSync DO", error as Error, {
          priority_twist_id: record.priority_twist_id,
        });
      }
    }
  }
}
