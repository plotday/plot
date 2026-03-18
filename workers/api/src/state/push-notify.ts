import { DurableObject } from "cloudflare:workers";
import { sql } from "kysely";

import { createLogger } from "@plotday/worker-util";

import { withDb } from "../db";
import type { Bindings } from "../env";
import { sendDataNotificationToUser } from "../notifications/send";

/** Urgency priority: lower = more urgent */
const URGENCY_RANK: Record<string, number> = {
  interrupt: 0,
  "inform-requests": 1,
  "inform-updates": 2,
  passive: 3,
};

/** Default delay per urgency level (ms) — used when no priority see_within setting exists */
const DEFAULT_DELAY_MS: Record<string, number> = {
  interrupt: 0,
  "inform-requests": 30 * 60 * 1000, // 30 minutes
  "inform-updates": 60 * 60 * 1000, // 1 hour
};

/** Minimum interval between push notifications to the same user (ms) */
const MIN_PUSH_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

export class PushNotify extends DurableObject<Bindings> {
  private userId: string | null = null;
  private highestUrgency: string | null = null;
  private firstNotifyTime: number = 0;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/notify" && request.method === "POST") {
      const body = await request.json<{ userId: string }>();
      if (!body.userId) {
        return new Response("Missing userId", { status: 400 });
      }
      await this.handleNotify(body.userId);
      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  private async handleNotify(userId: string): Promise<void> {
    // Store userId on first notify
    if (!this.userId) {
      this.userId = userId;
      await this.ctx.storage.put("userId", userId);
    }

    const now = Date.now();
    if (this.firstNotifyTime === 0) {
      this.firstNotifyTime = now;
      await this.ctx.storage.put("firstNotifyTime", now);
    }

    // Query the max urgency and effective see_within delay for this user's unread threads
    let maxUrgency: string | null = null;
    let delayMs = 0;
    try {
      const result = await withDb(this.env, async (db) => {
        const urgencyResult = await sql<{
          urgency: string;
          see_within_requests: string | null;
          see_within_updates: string | null;
        }>`
          SELECT
            tu.urgency,
            psi.see_within_requests,
            psi.see_within_updates
          FROM thread_unread tu
          JOIN thread t ON t.id = tu.thread_id
          LEFT JOIN LATERAL (
            SELECT
              MAX(CASE WHEN key = 'see_within_requests' THEN value::text END)::jsonb AS see_within_requests,
              MAX(CASE WHEN key = 'see_within_updates' THEN value::text END)::jsonb AS see_within_updates
            FROM priority_setting_inherited
            WHERE user_id = ${userId}::uuid AND priority_id = t.priority_id
          ) psi ON true
          WHERE tu.user_id = ${userId}::uuid AND tu.read_at IS NULL
            AND tu.urgency != 'passive'
          ORDER BY CASE tu.urgency
            WHEN 'interrupt' THEN 0
            WHEN 'inform-requests' THEN 1
            WHEN 'inform-updates' THEN 2
            ELSE 3
          END ASC
        `.execute(db);

        if (urgencyResult.rows.length === 0) return null;

        const topUrgency = urgencyResult.rows[0].urgency;

        // Find shortest delay across all unread threads matching the top urgency type
        let shortestDelay = DEFAULT_DELAY_MS[topUrgency] ?? DEFAULT_DELAY_MS["inform-updates"];

        for (const row of urgencyResult.rows) {
          let seeWithin: string | null = null;
          if (row.urgency === "inform-requests") {
            seeWithin = row.see_within_requests;
          } else if (row.urgency === "inform-updates") {
            seeWithin = row.see_within_updates;
          }

          if (seeWithin) {
            const ms = seeWithinToMs(seeWithin);
            if (ms !== null && ms < shortestDelay) {
              shortestDelay = ms;
            }
          }
        }

        return { urgency: topUrgency, delayMs: shortestDelay };
      });

      if (result) {
        maxUrgency = result.urgency;
        delayMs = result.delayMs;
      }
    } catch {
      // If DB query fails, default to inform-updates
      maxUrgency = "inform-updates";
      delayMs = DEFAULT_DELAY_MS["inform-updates"];
    }

    if (!maxUrgency) {
      // No unread threads (or all passive) — clear state
      this.highestUrgency = null;
      this.firstNotifyTime = 0;
      await this.ctx.storage.delete("highestUrgency");
      await this.ctx.storage.delete("firstNotifyTime");
      return;
    }

    const previousUrgency = this.highestUrgency;
    this.highestUrgency = maxUrgency;
    await this.ctx.storage.put("highestUrgency", maxUrgency);

    const currentAlarm = await this.ctx.storage.getAlarm();

    const multiplier = parseFloat(this.env.NOTIFICATION_DELAY_MULTIPLIER ?? "1.0");

    if (!currentAlarm) {
      // No pending alarm — schedule one
      await this.ctx.storage.setAlarm(now + delayMs * multiplier);
    } else if (
      previousUrgency &&
      (URGENCY_RANK[maxUrgency] ?? 2) < (URGENCY_RANK[previousUrgency] ?? 2)
    ) {
      // New urgency is higher — reschedule to sooner
      const newAlarmTime = now + delayMs * multiplier;
      if (newAlarmTime < currentAlarm) {
        await this.ctx.storage.setAlarm(newAlarmTime);
      }
    }
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "PushNotify",
      operation: "alarm",
    });

    // Restore state from storage
    if (!this.userId) {
      this.userId = (await this.ctx.storage.get<string>("userId")) ?? null;
    }
    if (!this.userId) {
      logger.error("PushNotify DO has no stored userId");
      return;
    }
    if (!this.highestUrgency) {
      this.highestUrgency =
        (await this.ctx.storage.get<string>("highestUrgency")) ?? null;
    }
    if (this.firstNotifyTime === 0) {
      this.firstNotifyTime =
        (await this.ctx.storage.get<number>("firstNotifyTime")) ?? 0;
    }

    try {
      // Check if user has connected WebSocket clients — skip if active
      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);
      const broadcastResponse = await broadcast.fetch(
        new Request("http://do/hasConnectedClients")
      );
      const broadcastData: any = await broadcastResponse.json();

      if (broadcastData.hasConnectedClients) {
        logger.info("Skipping push — user has connected clients", {
          user_id: this.userId,
        });
        this.resetState();
        return;
      }

      // Check minimum interval since last notification
      const lastSentAt =
        (await this.ctx.storage.get<number>("lastNotificationSentAt")) ?? 0;
      const now = Date.now();
      const multiplier = parseFloat(this.env.NOTIFICATION_DELAY_MULTIPLIER ?? "1.0");
      const effectiveMinInterval = MIN_PUSH_INTERVAL_MS * multiplier;
      if (now - lastSentAt < effectiveMinInterval && this.highestUrgency !== "interrupt") {
        // Too soon — reschedule
        const remainingMs = effectiveMinInterval - (now - lastSentAt);
        await this.ctx.storage.setAlarm(now + remainingMs);
        return;
      }

      // Send data-only FCM wake signal
      await withDb(this.env, async (db) => {
        await sendDataNotificationToUser(this.env, db, this.userId!, {
          type: "sync_wake",
        });
      });

      await this.ctx.storage.put("lastNotificationSentAt", now);

      logger.info("Push notification sent", {
        user_id: this.userId,
        urgency: this.highestUrgency,
      });
    } catch (error) {
      logger.error("Error in PushNotify alarm", error as Error, {
        user_id: this.userId,
      });
    } finally {
      this.resetState();
    }
  }

  private async resetState(): Promise<void> {
    this.highestUrgency = null;
    this.firstNotifyTime = 0;
    await this.ctx.storage.delete("highestUrgency");
    await this.ctx.storage.delete("firstNotifyTime");
  }
}

/** Convert a see_within JSON value like {"value":30,"unit":"minutes"} to milliseconds */
export function seeWithinToMs(raw: string | null): number | null {
  if (!raw) return null;
  try {
    const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
    const value = parsed?.value;
    const unit = parsed?.unit;
    if (typeof value !== "number" || !unit) return null;
    switch (unit) {
      case "minutes": return value * 60 * 1000;
      case "hours": return value * 60 * 60 * 1000;
      case "days": return value * 24 * 60 * 60 * 1000;
      default: return null;
    }
  } catch {
    return null;
  }
}
