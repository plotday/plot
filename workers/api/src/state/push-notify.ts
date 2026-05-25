import { DurableObject } from "cloudflare:workers";
import { sql } from "kysely";
import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { withDb } from "../db";
import type { Bindings } from "../env";
import { sendDataNotificationToUser } from "../notifications/send";

// The server no longer schedules notification timing. Once a notify-eligible
// unread thread exists, the DO sends a `sync_wake` so the client can sync
// and run its own deferred-delivery scheduler (block-start vs see-within
// deadline vs notify-window). Only two server-side gates remain:
//   - INACTIVITY_THRESHOLD_MS: skip waking devices while one is actively used.
//   - MIN_PUSH_INTERVAL_MS: collapse bursts so we don't burn battery / FCM quota.
// Urgent threads bypass both gates.

/** Minimum interval between push notifications to the same user (ms) */
const MIN_PUSH_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

/**
 * How long the user must be inactive on every connected client before we
 * actually fire a push for unread threads they didn't read.
 *
 * The alarm reschedules itself while any client is reporting `active: true`
 * (window focused + foreground); once nobody has pinged active for this
 * long, the push fires. Urgent items bypass this gate.
 */
const INACTIVITY_THRESHOLD_MS = 10 * 60 * 1000; // 10 minutes

/** Importance below this value never triggers a push or scheduling on its own. */
const IMPORTANCE_NOTIFY_THRESHOLD = 50;

export class PushNotify extends DurableObject<Bindings> {
  private userId: string | null = null;
  private hasUrgent: boolean = false;
  private firstNotifyTime: number = 0;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
  }

  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, this.userId ?? undefined, {
      durable_object: "PushNotify",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
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

    // Look for any notify-eligible unread thread. The client owns timing
    // now, so we only need to know:
    //   (a) is there anything to wake the client about, and
    //   (b) is any of it urgent (which lets the alarm bypass the
    //       inactivity and min-interval gates).
    let hasUrgent = false;
    let latestUnreadAt: string | null = null;
    let hadCandidates = false;
    try {
      const result = await withDb(this.env, async (db) => {
        const stateResult = await sql<{
          any_urgent: boolean;
          latest_updated_at: string;
        }>`
          SELECT
            BOOL_OR(ts.urgent) AS any_urgent,
            MAX(ts.updated_at)::text AS latest_updated_at
          FROM thread_state ts
          JOIN thread t ON t.id = ts.thread_id
          JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
          WHERE ts.user_id = ${userId}::uuid AND ts.read_at IS NULL
            AND (ts.importance >= ${IMPORTANCE_NOTIFY_THRESHOLD} OR ts.urgent = TRUE)
            AND t.archived_at IS NULL
            AND (t.draft = false OR t.created_by = ${userId}::uuid)
            AND (
              t.contacts && "user".user_contact_ids(${userId}::uuid)
              OR t.groups && "user".user_group_ids(${userId}::uuid)
            )
        `.execute(db);

        const row = stateResult.rows[0];
        if (!row || !row.latest_updated_at) return null;
        return { urgent: row.any_urgent, latestUnreadAt: row.latest_updated_at };
      });

      if (result) {
        hasUrgent = result.urgent;
        latestUnreadAt = result.latestUnreadAt;
        hadCandidates = true;
      }
    } catch (error) {
      // If the DB query fails, fall back to a non-urgent wake. The client
      // will still sync and decide what to show.
      hasUrgent = false;
      hadCandidates = true;
      this.captureException(error as Error);
    }

    if (!hadCandidates) {
      // No notify-worthy unread threads — clear state.
      this.hasUrgent = false;
      this.firstNotifyTime = 0;
      await this.ctx.storage.delete("hasUrgent");
      await this.ctx.storage.delete("firstNotifyTime");
      return;
    }

    // Skip if we already notified about these exact unreads (no new activity)
    if (latestUnreadAt) {
      const lastNotifiedUnreadAt =
        await this.ctx.storage.get<string>("lastNotifiedUnreadAt");
      if (lastNotifiedUnreadAt && latestUnreadAt <= lastNotifiedUnreadAt) {
        // No new unread activity since last push — don't re-notify
        return;
      }
    }

    const wasUrgent = this.hasUrgent;
    this.hasUrgent = hasUrgent;
    await this.ctx.storage.put("hasUrgent", hasUrgent);

    // Fire as soon as the alarm runner will pick us up. The alarm handler
    // still applies the inactivity and min-interval gates; urgent bypasses
    // both. There's no longer a server-side `see_within` delay — the client
    // schedules its own deferred delivery on receipt of the wake.
    const currentAlarm = await this.ctx.storage.getAlarm();
    if (!currentAlarm || (hasUrgent && !wasUrgent && currentAlarm > now)) {
      await this.ctx.storage.setAlarm(now);
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
    if (!this.hasUrgent) {
      this.hasUrgent = (await this.ctx.storage.get<boolean>("hasUrgent")) ?? false;
    }
    if (this.firstNotifyTime === 0) {
      this.firstNotifyTime =
        (await this.ctx.storage.get<number>("firstNotifyTime")) ?? 0;
    }

    try {
      // Defer push while any of the user's clients is reporting active.
      // We use the per-client `last_active_at` recorded in Broadcast's
      // `device_activity` table rather than the raw connection count so
      // that an open-but-unfocused desktop window stops blocking pushes
      // to mobile once the user actually walks away. Urgent items skip
      // this gate entirely.
      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);
      const broadcastResponse = await broadcast.fetch(
        new Request("http://do/last-active")
      );
      const broadcastData = await broadcastResponse.json<{
        lastActiveAt: string | null;
      }>();

      const now = Date.now();
      const multiplier = parseFloat(this.env.NOTIFICATION_DELAY_MULTIPLIER ?? "1.0");
      const inactivityThresholdMs = INACTIVITY_THRESHOLD_MS * multiplier;

      if (broadcastData.lastActiveAt && !this.hasUrgent) {
        const lastActiveMs = Date.parse(broadcastData.lastActiveAt);
        const idleFor = now - lastActiveMs;
        if (Number.isFinite(lastActiveMs) && idleFor < inactivityThresholdMs) {
          // User is still active (or was within the threshold). Reschedule
          // the alarm to fire once the inactivity window has fully elapsed
          // since the last active ping. The alarm will re-check then —
          // if the user is still active it reschedules again.
          const remainingMs = Math.max(1000, inactivityThresholdMs - idleFor);
          await this.ctx.storage.setAlarm(now + remainingMs);
          logger.info("Deferring push — user recently active", {
            user_id: this.userId,
            idle_for_ms: idleFor,
            retry_in_ms: remainingMs,
          });
          return;
        }
      }

      // Check minimum interval since last notification (urgent items bypass).
      const lastSentAt =
        (await this.ctx.storage.get<number>("lastNotificationSentAt")) ?? 0;
      const effectiveMinInterval = MIN_PUSH_INTERVAL_MS * multiplier;
      if (now - lastSentAt < effectiveMinInterval && !this.hasUrgent) {
        const remainingMs = effectiveMinInterval - (now - lastSentAt);
        await this.ctx.storage.setAlarm(now + remainingMs);
        return;
      }

      // Re-check that we still have a notify-worthy unread (importance >= 50
      // OR urgent). The user may have read everything since the alarm was
      // scheduled.
      let latestUnreadAt: string | null = null;
      await withDb(this.env, async (db) => {
        const result = await sql<{ latest: string }>`
          SELECT MAX(ts.updated_at)::text AS latest
          FROM thread_state ts
          JOIN thread t ON t.id = ts.thread_id
          JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${this.userId!}::uuid
          WHERE ts.user_id = ${this.userId!}::uuid
            AND ts.read_at IS NULL
            AND (ts.importance >= ${IMPORTANCE_NOTIFY_THRESHOLD} OR ts.urgent = TRUE)
            AND t.archived_at IS NULL
            AND (t.draft = false OR t.created_by = ${this.userId!}::uuid)
            AND (
              t.contacts && "user".user_contact_ids(${this.userId!}::uuid)
              OR t.groups && "user".user_group_ids(${this.userId!}::uuid)
            )
        `.execute(db);
        latestUnreadAt = result.rows[0]?.latest ?? null;

        if (latestUnreadAt) {
          // Send data-only FCM wake signal
          await sendDataNotificationToUser(this.env, db, this.userId!, {
            type: "sync_wake",
          });
        }
      });

      if (!latestUnreadAt) {
        // No notify-worthy unreads — user read everything since alarm was scheduled
        logger.info("Skipping push — no notify-worthy unreads remaining", {
          user_id: this.userId,
        });
        return;
      }

      await this.ctx.storage.put("lastNotificationSentAt", now);

      // Record what we notified about so we don't re-notify for the same unreads
      await this.ctx.storage.put("lastNotifiedUnreadAt", latestUnreadAt);

      // Trigger email digest check — if user doesn't open the app within 18h,
      // they'll receive an email with all unread notifications
      const emailNotifyId = this.env.EMAIL_NOTIFY.idFromName(this.userId!);
      const emailNotifyDO = this.env.EMAIL_NOTIFY.get(emailNotifyId);
      this.ctx.waitUntil(
        emailNotifyDO
          .fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ userId: this.userId }),
            })
          )
          .catch((error) => {
            this.captureException(error as Error, {
              context: "email-notify-trigger",
            });
          })
      );

      logger.info("Push notification sent", {
        user_id: this.userId,
        urgent: this.hasUrgent,
      });
    } catch (error) {
      logger.error("Error in PushNotify alarm", error as Error, {
        user_id: this.userId,
      });
      this.captureException(error as Error);
    } finally {
      this.resetState();
    }
  }

  private async resetState(): Promise<void> {
    this.hasUrgent = false;
    this.firstNotifyTime = 0;
    await this.ctx.storage.delete("hasUrgent");
    await this.ctx.storage.delete("firstNotifyTime");
    // Note: lastNotifiedUnreadAt and lastNotificationSentAt are NOT cleared —
    // they persist across notification cycles to prevent re-notifying.
  }
}
