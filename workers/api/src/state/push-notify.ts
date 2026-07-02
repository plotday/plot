import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";

import { isTransientDbError, withDb } from "../db";
import type { Bindings } from "../env";
import { sendDataNotificationToUser } from "../notifications/send";
import {
  isTransientDoResetError,
  transientErrorReason,
} from "../utils/transient-error";
import { selectNotifyCandidates } from "./notify-candidates";

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

/**
 * Transient infrastructure errors that should be logged but NOT paged to
 * PostHog Error Tracking. Covers both the Cloudflare DO-reset family
 * (storage-timeout reset, generic platform fault, DO-to-DO fetch drop) and
 * the Hyperdrive/pg connection drops that surface on the same alarm path.
 * Both self-resolve: the DO is reset and the next notify() schedules a fresh
 * alarm. PostHog issue 019ebd3b paged 7 times from PushNotify.alarm for
 * "Durable Object storage operation exceeded timeout which caused object to
 * be reset" and "Connection terminated unexpectedly" before this gate.
 */
function isTransientNotifyError(error: unknown): boolean {
  return isTransientDoResetError(error) || isTransientDbError(error);
}

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
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.captureException(error, this.userId ?? undefined, {
      durable_object: "PushNotify",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  /**
   * Emit a `push.transient` counter (NOT a captureException — these are
   * expected, self-healing platform blips) so a SUSTAINED spike is still
   * visible. A code-level "N in a row" floor would live in DO state that a
   * platform reset wipes, so detection is delegated to a server-side PostHog
   * volume alert over this counter (infra/posthog/alerts.tf), mirroring the
   * `bg.deferred` capacity-pressure alert. `system` distinct id keeps it a
   * pure rate (no per-user cardinality); `reason` is the breakdown dimension.
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
        durable_object: "PushNotify",
        reason: transientErrorReason(error),
      },
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
    let hadCandidates = false;
    try {
      const result = await withDb(this.env, async (db) => {
        const candidates = await selectNotifyCandidates(db, userId);
        if (candidates.length === 0) return null;
        return { urgent: candidates.some((c) => c.urgent) };
      });

      if (result) {
        hasUrgent = result.urgent;
        hadCandidates = true;
      }
    } catch (error) {
      // If the DB query fails, fall back to a non-urgent wake. The client
      // will still sync and decide what to show.
      hasUrgent = false;
      hadCandidates = true;
      // A transient Hyperdrive/pg drop or DO reset here is platform noise —
      // the fallback wake covers it. Count it for the volume alert, but only
      // page on real, unexpected failures.
      if (isTransientNotifyError(error)) {
        this.captureTransientCounter(error);
      } else {
        this.captureException(error as Error);
      }
    }

    if (!hadCandidates) {
      // No notify-worthy unread threads — clear state.
      this.hasUrgent = false;
      this.firstNotifyTime = 0;
      await this.ctx.storage.delete("hasUrgent");
      await this.ctx.storage.delete("firstNotifyTime");
      // Purge the now-unused dedup key left by older DO instances. Re-notify
      // suppression is handled by priority.notification_cleared_at, not this.
      await this.ctx.storage.delete("lastNotifiedUnreadAt");
      return;
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
      // OR urgent). The user may have read everything — or moved/cleared it —
      // since the alarm was scheduled.
      let hasCandidates = false;
      await withDb(this.env, async (db) => {
        const candidates = await selectNotifyCandidates(db, this.userId!);
        hasCandidates = candidates.length > 0;

        if (hasCandidates) {
          // Send data-only FCM wake signal
          await sendDataNotificationToUser(this.env, db, this.userId!, {
            type: "sync_wake",
          });
        }
      });

      if (!hasCandidates) {
        // No notify-worthy unreads — user read everything since alarm was scheduled
        logger.info("Skipping push — no notify-worthy unreads remaining", {
          user_id: this.userId,
        });
        return;
      }

      await this.ctx.storage.put("lastNotificationSentAt", now);

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
      // Transient Cloudflare DO resets (storage-timeout reset, platform fault,
      // DO-to-DO fetch drop) and Hyperdrive/pg connection drops are platform
      // noise — the DO is reset and the next notify() schedules a fresh alarm.
      // Log them but don't page Error Tracking (PostHog issue 019ebd3b).
      if (isTransientNotifyError(error)) {
        logger.warn("PushNotify alarm interrupted by transient platform error", {
          user_id: this.userId,
          error_message: (error as Error).message,
        });
        // Count it so a sustained spike trips the volume alert even though no
        // individual occurrence pages (infra/posthog/alerts.tf).
        this.captureTransientCounter(error);
      } else {
        logger.error("Error in PushNotify alarm", error as Error, {
          user_id: this.userId,
        });
        this.captureException(error as Error);
      }
    } finally {
      this.resetState();
    }
  }

  private async resetState(): Promise<void> {
    this.hasUrgent = false;
    this.firstNotifyTime = 0;
    await this.ctx.storage.delete("hasUrgent");
    await this.ctx.storage.delete("firstNotifyTime");
    // Note: lastNotificationSentAt is NOT cleared — it persists across
    // notification cycles to enforce the min-push-interval gate. Re-notify
    // suppression now lives in priority.notification_cleared_at.
  }
}
