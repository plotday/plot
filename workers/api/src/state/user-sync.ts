import { DurableObject } from "cloudflare:workers";
import type { Kysely } from "kysely";

import { type DB, createDb } from "../db";
import { rpc } from "../rpc";
import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc } from "../utils/rpc";

// Debouncing configuration (compile-time constants)
const MIN_WAIT_MS = 100; // Minimum time to wait before sending, allowing batching
const MAX_WAIT_MS = 2000; // Maximum time to wait if updates keep arriving
const MIN_INTERVAL_MS = 500; // Minimum gap between sync deliveries

interface UserSyncState {
  lastNotifyTime: number;
  lastSyncTime: number;
  pendingAlarm: boolean;
}

export class UserSync extends DurableObject<Bindings> {
  private db: Kysely<DB>;
  private userId: string | null = null;
  private state: UserSyncState;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.db = createDb(env);
    this.state = {
      lastNotifyTime: 0,
      lastSyncTime: 0,
      pendingAlarm: false,
    };
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/notify" && request.method === "POST") {
      const body = await request.json<{ id: string }>();
      if (!body.id) {
        return new Response("Missing id", { status: 400 });
      }
      await this.notify(body.id);
      return new Response("OK", { status: 200 });
    }

    if (url.pathname === "/onClientConnected" && request.method === "POST") {
      const body = await request.json<{ userId: string }>();
      if (!body.userId) {
        return new Response("Missing userId", { status: 400 });
      }
      await this.onClientConnected(body.userId);
      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  /**
   * Called when the API receives a sync notification
   * Schedules an alarm based on debouncing rules
   */
  private async notify(userId: string): Promise<void> {
    // Store userId on first notify
    if (!this.userId) {
      this.userId = userId;
      await this.ctx.storage.put("userId", userId);
    }

    const now = Date.now();
    this.state.lastNotifyTime = now;

    // If we have a pending alarm, let it handle the sync
    if (this.state.pendingAlarm) {
      return;
    }

    // Calculate when we should sync
    const timeSinceLastSync = now - this.state.lastSyncTime;
    let delayMs: number;

    if (timeSinceLastSync < MIN_INTERVAL_MS) {
      // If we synced recently, wait until MIN_INTERVAL_MS has passed
      delayMs = MIN_INTERVAL_MS - timeSinceLastSync;
    } else {
      // Otherwise, use MIN_WAIT_MS to allow batching
      delayMs = MIN_WAIT_MS;
    }

    // Schedule the alarm
    this.state.pendingAlarm = true;
    await this.ctx.storage.setAlarm(now + delayMs);
  }

  /**
   * Called when the alarm fires
   * Performs the sync if conditions are met
   */
  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "UserSync",
      operation: "alarm",
    });

    this.state.pendingAlarm = false;

    // Get userId from storage
    if (!this.userId) {
      const storedUserId = await this.ctx.storage.get<string>("userId");
      if (storedUserId) {
        this.userId = storedUserId;
      } else {
        logger.error("UserSync DO has no stored userId - notify() was never called");
        return;
      }
    }

    const timingEnabled = this.env.SYNC_TIMING_ENABLED === "true";

    try {
      const now = Date.now();
      if (now - this.state.lastNotifyTime < MIN_WAIT_MS) {
        // More notifications came in recently, reschedule
        const delayMs = MIN_WAIT_MS - (now - this.state.lastNotifyTime);
        this.state.pendingAlarm = true;
        await this.ctx.storage.setAlarm(now + delayMs);
        return;
      }

      // Enforce MAX_WAIT_MS - if we've been waiting too long, sync now
      if (
        this.state.lastNotifyTime > 0 &&
        now - this.state.lastNotifyTime > MAX_WAIT_MS
      ) {
        // Waited long enough, proceed with sync
      }

      // Check if there are connected clients
      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);
      const broadcastResponse = await broadcast.fetch(
        new Request("http://do/hasConnectedClients")
      );
      const broadcastData: any = await broadcastResponse.json();
      disposeRpc(broadcastResponse);
      const hasClients = broadcastData.hasConnectedClients;

      if (!hasClients) {
        // No connected clients, skip sync
        logger.info("Skipping sync - no connected clients", {
          user_id: this.userId,
        });
        this.state.lastSyncTime = now;
        return;
      }

      // Query pending updates using RPC to compare columns
      let pendingUpdates: Awaited<ReturnType<typeof rpc<"get_pending_user_sync">>>;
      try {
        pendingUpdates = await rpc(this.db, "get_pending_user_sync", {
          p_user_id: this.userId,
        });
      } catch (error) {
        logger.error("Error querying user_sync", error as Error, {
          user_id: this.userId,
        });
        return;
      }

      if (!pendingUpdates || !Array.isArray(pendingUpdates) || pendingUpdates.length === 0) {
        // No pending updates
        this.state.lastSyncTime = now;
        return;
      }

      // Calculate the sync timestamp from query results (max last_update_at)
      // This ensures we use database timestamps consistently rather than local server time
      // and avoids race conditions where new updates could arrive between query and mark complete
      const syncUpTo = pendingUpdates.reduce((max, update) => {
        return update.last_update_at > max ? update.last_update_at : max;
      }, pendingUpdates[0]?.last_update_at);

      // Send sync messages for each entity
      for (const update of pendingUpdates) {
        const result = await broadcast.send({
          type: "sync",
          table: update.entity,
        });
        disposeRpc(result);
      }

      // Update last_sync_at for the entities we just synced using the max timestamp from the query
      // Sort entities alphabetically to ensure consistent lock order and prevent deadlocks
      const entities = pendingUpdates.map((u) => u.entity).sort();

      // Retry logic for deadlock errors (PostgreSQL code 40P01)
      let retryCount = 0;
      const maxRetries = 3;
      let updateError: any = null;

      while (retryCount <= maxRetries) {
        try {
          await this.db
            .updateTable("user_sync")
            .set({ last_sync_at: syncUpTo })
            .where("user_id", "=", this.userId)
            .where("entity", "in", entities)
            .execute();

          updateError = null;
          break;
        } catch (error: any) {
          // Check if this is a deadlock error
          if (error?.code === "40P01" && retryCount < maxRetries) {
            retryCount++;
            // Exponential backoff with jitter: 50-100ms, 100-200ms, 200-400ms
            const baseDelay = 50 * Math.pow(2, retryCount - 1);
            const jitter = Math.random() * baseDelay;
            const delayMs = baseDelay + jitter;

            logger.warn(`Deadlock detected, retrying (${retryCount}/${maxRetries})`, {
              user_id: this.userId,
              delay_ms: Math.round(delayMs),
            });

            await new Promise((resolve) => setTimeout(resolve, delayMs));
            continue;
          }

          // Non-deadlock error or max retries exceeded
          updateError = error;
          break;
        }
      }

      if (updateError) {
        logger.error("Error updating user_sync last_sync_at", updateError, {
          user_id: this.userId,
          retry_count: retryCount,
        });
      }

      this.state.lastSyncTime = now;

      const syncDispatchMs = Date.now() - now;

      if (timingEnabled) {
        logger.info("User sync dispatch timing", {
          user_id: this.userId,
          sync_dispatch_ms: syncDispatchMs,
          pending_entity_count: pendingUpdates.length,
          entities: pendingUpdates.map((u) => u.entity),
        });
      }

      logger.info("User sync completed", {
        user_id: this.userId,
        entity_count: pendingUpdates.length,
        entities: pendingUpdates.map((u) => u.entity),
      });
    } catch (error) {
      logger.error("Error in UserSync alarm", error as Error, {
        user_id: this.userId,
      });
    }
  }

  /**
   * Called when a client connects to the Broadcast DO
   * Syncs user_sync table so incremental updates work correctly
   */
  async onClientConnected(userId: string): Promise<void> {
    const logger = createLogger({
      durable_object: "UserSync",
      operation: "onClientConnected",
    });

    // Store userId for future use
    if (!this.userId) {
      this.userId = userId;
      await this.ctx.storage.put("userId", userId);
    }

    try {
      // Call database function to sync last_sync_at to match last_update_at
      // This ensures incremental updates work correctly after client reconnects
      await rpc(this.db, "sync_user_on_connect", {
        p_user_id: userId,
      });

      logger.info("User sync state updated on client connect", {
        user_id: userId,
      });
    } catch (error) {
      logger.error("Error in onClientConnected", error as Error, {
        user_id: userId,
      });
    }
  }
}
