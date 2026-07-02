import { DurableObject } from "cloudflare:workers";
import { sql } from "kysely";
import { PostHog } from "posthog-node";

import { withDb } from "../db";
import { rpc } from "../rpc";
import type { Bindings } from "../env";
import {
  isTransientDoResetError,
  transientErrorReason,
} from "../utils/transient-error";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import { TransientAlarmRetry, isTransientAlarmError } from "./alarm-retry";

// Debouncing configuration (compile-time constants)
const MIN_WAIT_MS = 300; // Minimum time to wait before sending, allowing batching
const MAX_WAIT_MS = 2000; // Maximum time a batch can sit waiting before forced flush
const MIN_INTERVAL_MS = 500; // Minimum gap between sync deliveries

interface UserSyncState {
  lastNotifyTime: number;
  lastSyncTime: number;
  // Time of the first notify in the current batch — anchors MAX_WAIT_MS so a
  // continuous stream of notifies can't keep rescheduling the alarm forever.
  // Reset to 0 after each successful broadcast.
  batchStartTime: number;
  pendingAlarm: boolean;
}

export class UserSync extends DurableObject<Bindings> {
  private userId: string | null = null;
  private state: UserSyncState;
  // Consecutive transient-error retry budget since the last fresh notify().
  // Reset in notify() so user activity restores the full budget.
  private retry = new TransientAlarmRetry();

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.state = {
      lastNotifyTime: 0,
      lastSyncTime: 0,
      batchStartTime: 0,
      pendingAlarm: false,
    };
    // Load userId from storage on DO initialization to avoid storage reads
    // in the alarm handler, reducing the chance of hitting DO storage timeouts.
    ctx.blockConcurrencyWhile(async () => {
      const storedUserId = await ctx.storage.get<string>("userId");
      if (storedUserId) {
        this.userId = storedUserId;
      }
    });
  }

  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.captureException(error, this.userId ?? undefined, {
      durable_object: "UserSync",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  /**
   * Emit a `push.transient` counter (NOT a captureException) for each
   * suppressed transient platform blip, so a SUSTAINED spike trips the
   * server-side volume alert (infra/posthog/alerts.tf) even though individual
   * occurrences self-heal via the retry/reschedule below. Shares the
   * `push.transient` event + `reason` breakdown with PushNotify so one alert
   * watches the whole push-delivery path; `durable_object` distinguishes them.
   */
  private captureTransientCounter(error: unknown) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.capture({
      distinctId: "system",
      event: "push.transient",
      properties: {
        durable_object: "UserSync",
        reason: transientErrorReason(error),
      },
    });
    this.ctx.waitUntil(postHog.shutdown());
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
    // Fresh user activity restores the transient-retry budget so a future
    // alarm chain gets the full set of attempts again.
    this.retry.reset();
    if (this.state.batchStartTime === 0) {
      this.state.batchStartTime = now;
    }

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

    if (!this.userId) {
      logger.error("UserSync DO has no stored userId - notify() was never called");
      return;
    }

    const timingEnabled = this.env.SYNC_TIMING_ENABLED === "true";

    // Per-step timings. Attached to outer error/warn logs so that when a DO
    // storage timeout aborts the alarm, we can see which await was in flight.
    const timings: Record<string, number> = {};
    const alarmStart = Date.now();
    let currentStep: string = "init";
    const markStep = (name: string, since: number) => {
      timings[name] = Date.now() - since;
      currentStep = name;
    };

    try {
      const now = Date.now();
      const sinceLastNotify = now - this.state.lastNotifyTime;
      const batchAge =
        this.state.batchStartTime > 0 ? now - this.state.batchStartTime : 0;

      // If notifies are still arriving rapidly AND we haven't held this batch
      // open for too long, reschedule to keep coalescing. The MAX_WAIT_MS cap
      // guarantees the batch fires even under sustained load.
      if (sinceLastNotify < MIN_WAIT_MS && batchAge < MAX_WAIT_MS) {
        const delayMs = Math.min(
          MIN_WAIT_MS - sinceLastNotify,
          MAX_WAIT_MS - batchAge
        );
        this.state.pendingAlarm = true;
        currentStep = "setAlarmReschedule";
        await this.ctx.storage.setAlarm(now + delayMs);
        return;
      }

      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);

      // Always invoke PushNotify, regardless of whether any client is
      // currently connected. PushNotify owns the deferral logic — it
      // reschedules its alarm while a client is active and only fires the
      // push after the user has been inactive for the inactivity window.
      // (Pre-change this was guarded by `!hasClients`, which meant a single
      // open desktop tab suppressed pushes to all of the user's mobile
      // devices forever.)
      //
      // Fire-and-forget to avoid blocking the alarm handler (PushNotify
      // runs a DB query + storage ops that can exceed DO timeout limits).
      const pushNotifyId = this.env.PUSH_NOTIFY.idFromName(this.userId);
      const pushNotifyDO = this.env.PUSH_NOTIFY.get(pushNotifyId);
      this.ctx.waitUntil(
        pushNotifyDO
          .fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ userId: this.userId }),
            })
          )
          .catch((error) => {
            // DO resets in PushNotify are transient platform noise;
            // don't capture, but keep a warn-level breadcrumb.
            if (isTransientDoResetError(error)) {
              logger.warn("PushNotify DO interrupted by DO reset", {
                user_id: this.userId ?? undefined,
              });
              return;
            }
            logger.error("Error triggering PushNotify DO", error as Error, {
              user_id: this.userId ?? undefined,
            });
            this.captureException(error as Error);
          })
      );

      // Don't gate broadcast on `hasConnectedClients`. `inactiveClients` (set
      // by clients sending `{active: false}`) exists to ensure other devices
      // still get FCM when a desktop app is backgrounded — it must NOT
      // suppress WebSocket delivery to those backgrounded clients, which still
      // hold open sockets. `broadcast.send` is a no-op when no sockets are
      // open; otherwise it correctly fans out to every connected client.

      const userId = this.userId;
      currentStep = "withDb";
      await withDb(this.env, async (db) => {
        // rpc() unwraps single-row TABLE results into a bare object, so a
        // single pending entity (the common case) would slip past an
        // Array.isArray check. Normalize to an array.
        const tRpc = Date.now();
        currentStep = "getPendingUserSync";
        const pendingUpdatesRaw = await rpc(db, "get_pending_user_sync", {
          p_user_id: userId,
        });
        markStep("getPendingUserSyncMs", tRpc);

        const pendingUpdates = Array.isArray(pendingUpdatesRaw)
          ? pendingUpdatesRaw
          : pendingUpdatesRaw
            ? [pendingUpdatesRaw]
            : [];
        timings.pendingEntityCount = pendingUpdates.length;

        if (pendingUpdates.length === 0) {
          this.state.lastSyncTime = now;
          this.state.batchStartTime = 0;
          return;
        }

        // Send a single sync message carrying all dirty tables. `table` is
        // included for backwards compatibility with older clients that only
        // read the singular field — they'll pull at least one entity, then
        // the next broadcast catches the rest.
        const tables = pendingUpdates.map((u) => u.entity);
        const tSend = Date.now();
        currentStep = "broadcastSend";
        await broadcast.send({
          type: "sync",
          tables,
          table: tables[0],
        });
        markStep("broadcastSendMs", tSend);

        // Advance both watermarks atomically in SQL: last_sync_at follows
        // last_update_at (full μs precision; JS Date would lose microseconds
        // and leave last_update_at > last_sync_at permanently true) and
        // last_sync_seq follows last_update_seq (the new xid8 cursor that
        // sync queries on /sync/* gate on; bumped by sync_user_for_*
        // triggers).
        const entities = pendingUpdates.map((u) => u.entity).sort();

        // Retry logic for deadlock errors (PostgreSQL code 40P01)
        let retryCount = 0;
        const maxRetries = 3;
        let updateError: any = null;
        const tUpdate = Date.now();

        while (retryCount <= maxRetries) {
          try {
            currentStep = retryCount === 0 ? "updateUserSync" : `updateUserSyncRetry${retryCount}`;
            await db
              .updateTable("user_sync")
              .set({
                last_sync_at: sql`last_update_at`,
                last_sync_seq: sql`last_update_seq`,
              } as any)
              .where("user_id", "=", userId)
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
                user_id: userId,
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
        markStep("updateUserSyncMs", tUpdate);
        timings.updateRetryCount = retryCount;

        if (updateError) {
          logger.error("Error updating user_sync last_sync_at", updateError, {
            user_id: userId,
            retry_count: retryCount,
          });
        }

        this.state.lastSyncTime = now;
        this.state.batchStartTime = 0;

        if (timingEnabled) {
          logger.info("User sync dispatch timing", {
            user_id: userId,
            sync_dispatch_ms: Date.now() - now,
            pending_entity_count: pendingUpdates.length,
            entities: pendingUpdates.map((u) => u.entity),
          });
        }

        logger.info("User sync completed", {
          user_id: userId,
          entity_count: pendingUpdates.length,
          entities: pendingUpdates.map((u) => u.entity),
        });
      });
    } catch (error) {
      timings.totalMs = Date.now() - alarmStart;
      // DO resets, DO-to-DO network blips, and Hyperdrive/pg connection
      // drops are transient platform errors. Reschedule a self-heal so a
      // quiescent user (no further notify() incoming) doesn't sit on a
      // stuck pending update. After the retry ladder is exhausted, treat
      // it as a real error so a misclassified persistent failure surfaces.
      if (isTransientAlarmError(error)) {
        // Count every occurrence (before deciding to reschedule vs. capture)
        // so a sustained spike trips the volume alert (infra/posthog/alerts.tf)
        // — the per-DO retry budget below only captures AFTER it's exhausted.
        this.captureTransientCounter(error);
        const handled = await this.retry.reschedule({
          storage: this.ctx.storage,
          logger,
          error,
          durableObject: "UserSync",
          logContext: {
            user_id: this.userId,
            in_flight_step: currentStep,
            ...timings,
          },
          beforeSchedule: () => {
            this.state.pendingAlarm = true;
          },
          onScheduleFailed: () => {
            // Fall back to next-notify/SyncRecovery — we can't do better
            // without storage.
            this.state.pendingAlarm = false;
          },
        });
        if (handled) return;
        // Retry budget exhausted. The error is no longer "transient" by
        // any useful definition — capture it so we can investigate.
        logger.error(
          "UserSync alarm transient retries exhausted",
          error as Error,
          {
            user_id: this.userId,
            in_flight_step: currentStep,
            ...timings,
          },
        );
        this.captureException(error as Error, {
          in_flight_step: currentStep,
          retries_exhausted: true,
          ...timings,
        });
        return;
      }
      logger.error("Error in UserSync alarm", error as Error, {
        user_id: this.userId,
        in_flight_step: currentStep,
        ...timings,
      });
      this.captureException(error as Error, {
        in_flight_step: currentStep,
        ...timings,
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
      // Wrap in transaction so Hyperdrive sees the mutating RPC as a write
      await withDb(this.env, async (db) => {
        await db.transaction().execute(async (trx) => {
          await rpc(trx, "sync_user_on_connect", {
            p_user_id: userId,
          });
        });
      });

      logger.info("User sync state updated on client connect", {
        user_id: userId,
      });
    } catch (error) {
      logger.error("Error in onClientConnected", error as Error, {
        user_id: userId,
      });
      this.captureException(error as Error);
    }
  }
}
