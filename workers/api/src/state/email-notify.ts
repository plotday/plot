import { DurableObject } from "cloudflare:workers";
import { sql } from "kysely";
import { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";

import { withDb } from "../db";
import type { Bindings } from "../env";
import {
  generateSummary,
  fallbackSummary,
} from "../app/notification-summary";
import { transientErrorReason } from "../utils/transient-error";
import { TransientAlarmRetry, isTransientAlarmError } from "./alarm-retry";
import { selectDigestThreads } from "./email-digest-query";

/** 18 hours in milliseconds */
const EMAIL_DELAY_MS = 18 * 60 * 60 * 1000;

const BASE58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/** Encode a UUID string to base58 (matches the Flutter app's Uuid.toShortString). */
function uuidToBase58(uuid: string): string {
  const hex = uuid.replace(/-/g, "").toUpperCase();
  // Convert hex string to bigint
  let num = BigInt("0x" + hex);
  if (num === 0n) return BASE58_ALPHABET[0];
  let result = "";
  const base = BigInt(58);
  while (num > 0n) {
    result = BASE58_ALPHABET[Number(num % base)] + result;
    num = num / base;
  }
  return result;
}

/**
 * Canonical app deep link for a priority's feed.
 *
 * Returns `${appUrl}/p/{base58}` — the current `/p/:priorityId` route form.
 * The old digest link was the bare-segment legacy form `/{base58}?tab=activity`;
 * the `?tab=activity` query param is a vestige of a removed tabbed UI and is
 * ignored by the router, so we drop it and emit the canonical path directly.
 */
export function priorityDeepLinkUrl(
  appUrl: string,
  priorityId: string
): string {
  return `${appUrl}/p/${uuidToBase58(priorityId)}`;
}

export class EmailNotify extends DurableObject<Bindings> {
  private userId: string | null = null;
  private retry = new TransientAlarmRetry();

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
      durable_object: "EmailNotify",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  /**
   * Emit a `push.transient` counter (NOT a captureException — these are
   * expected, self-healing platform blips) so a SUSTAINED spike still trips
   * the server-side volume alert (infra/posthog/alerts.tf). Shares the event
   * + `reason` breakdown with PushNotify/UserSync so one alert watches the
   * whole notification-delivery path; `durable_object` distinguishes them.
   */
  private captureTransientCounter(error: unknown) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.capture({
      distinctId: "system",
      event: "push.transient",
      properties: {
        durable_object: "EmailNotify",
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
    if (!this.userId) {
      this.userId = userId;
      await this.ctx.storage.put("userId", userId);
    }

    // Fresh trigger restores the full transient-retry budget for the alarm.
    this.retry.reset();

    const multiplier = parseFloat(this.env.NOTIFICATION_DELAY_MULTIPLIER ?? "1.0");

    const pendingNotifyTime =
      (await this.ctx.storage.get<number>("pendingNotifyTime")) ?? 0;

    if (pendingNotifyTime > 0) {
      // Already have a pending cycle — keep the earlier window for batching.
      // But if its alarm was lost (a setAlarm failure or storage wipe left
      // the window orphaned), re-arm it at the original target so the digest
      // isn't stranded forever behind the `pendingNotifyTime > 0` guard.
      const scheduled = await this.ctx.storage.getAlarm();
      if (scheduled === null) {
        await this.ctx.storage.setAlarm(
          pendingNotifyTime + EMAIL_DELAY_MS * multiplier
        );
      }
      return;
    }

    const now = Date.now();
    await this.ctx.storage.put("pendingNotifyTime", now);

    await this.ctx.storage.setAlarm(now + EMAIL_DELAY_MS * multiplier);
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "EmailNotify",
      operation: "alarm",
    });

    // Restore state
    if (!this.userId) {
      this.userId = (await this.ctx.storage.get<string>("userId")) ?? null;
    }
    if (!this.userId) {
      logger.error("EmailNotify DO has no stored userId");
      return;
    }

    const pendingNotifyTime =
      (await this.ctx.storage.get<number>("pendingNotifyTime")) ?? 0;

    try {
      // Check if user has been active since the notification. Uses the
      // PERSISTED activity timestamp (not `/last-active`, which only reflects
      // currently-connected devices) — the user may have opened Plot hours ago
      // and since closed it, which should still suppress this digest.
      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);
      const broadcastResponse = await broadcast.fetch(
        new Request("http://do/last-active-persisted")
      );
      const { lastActiveAt } = (await broadcastResponse.json()) as {
        lastActiveAt: string | null;
      };

      if (lastActiveAt && pendingNotifyTime > 0) {
        const activeTime = new Date(lastActiveAt).getTime();
        if (activeTime > pendingNotifyTime) {
          logger.info("Skipping email — user was active since notification", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }
      }

      // Query all unread threads grouped by priority
      await withDb(this.env, async (db) => {
        const rows = await selectDigestThreads(db, this.userId!);

        if (rows.length === 0) {
          logger.info("Skipping email — no unread threads", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }

        // Dedup: check if there are new unreads since last email
        const latestUpdatedAt = rows[0].thread_updated_at;
        const lastEmailedUnreadAt =
          await this.ctx.storage.get<string>("lastEmailedUnreadAt");
        if (lastEmailedUnreadAt && latestUpdatedAt <= lastEmailedUnreadAt) {
          logger.info("Skipping email — no new unreads since last email", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }

        // Get user info
        const userResult = await sql<{
          email: string;
          name: string | null;
        }>`
          SELECT email, name FROM "user" WHERE id = ${this.userId!}::uuid
        `.execute(db);

        if (userResult.rows.length === 0) {
          logger.error("User not found for email notification", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }

        const user = userResult.rows[0];

        // Check user's email frequency preference and throttle accordingly.
        // NULL = default (send whenever pending), 'daily' = at most every 24h,
        // 'weekly' = at most every 7d, 'never' = skip entirely.
        const prefResult = await sql<{
          email_frequency: "daily" | "weekly" | "never" | null;
        }>`
          SELECT email_frequency FROM user_settings WHERE user_id = ${this.userId!}::uuid
        `.execute(db);
        const frequency = prefResult.rows[0]?.email_frequency ?? null;

        if (frequency === "never") {
          logger.info("Skipping email — user opted out", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }

        if (frequency === "daily" || frequency === "weekly") {
          const lastSentAt =
            (await this.ctx.storage.get<number>("lastEmailSentAt")) ?? 0;
          const minIntervalMs =
            frequency === "weekly"
              ? 7 * 24 * 60 * 60 * 1000
              : 24 * 60 * 60 * 1000;
          const sinceLast = Date.now() - lastSentAt;
          if (lastSentAt > 0 && sinceLast < minIntervalMs) {
            logger.info("Skipping email — within throttle window", {
              user_id: this.userId ?? undefined,
              frequency,
              since_last_ms: sinceLast,
            });
            await this.clearPending();
            return;
          }
        }

        // Ensure the user has an email_token used for unsubscribe links.
        const tokenResult = await sql<{ email_token: string }>`
          INSERT INTO user_settings (user_id, email_token)
            VALUES (${this.userId!}::uuid, gen_random_uuid())
          ON CONFLICT (user_id) DO UPDATE SET
            email_token = COALESCE(user_settings.email_token, EXCLUDED.email_token),
            updated_at = now()
          RETURNING email_token::text AS email_token
        `.execute(db);
        const emailToken = tokenResult.rows[0]?.email_token;

        // Group threads by first-level priority
        type PriorityGroup = {
          priorityId: string;
          title: string;
          threads: Array<{
            id: string;
            title: string | null;
            preview: string | null;
          }>;
        };
        const priorityMap = new Map<string, PriorityGroup>();

        for (const row of rows) {
          const segments = row.priority_path.split(".");
          const firstLevelPath = segments
            .slice(0, Math.min(2, segments.length))
            .join(".");

          let group = priorityMap.get(firstLevelPath);
          if (!group) {
            group = {
              priorityId: row.priority_id,
              title: row.priority_title,
              threads: [],
            };
            priorityMap.set(firstLevelPath, group);
          }

          group.threads.push({
            id: row.thread_id,
            title: row.thread_title,
            preview: row.thread_preview,
          });
        }

        // Look up first-level priority titles and IDs
        const firstLevelPaths = [...priorityMap.keys()];
        const firstLevelResult = await sql<{
          id: string;
          path: string;
          title: string;
        }>`
          SELECT id::text AS id, path::text AS path, title
          FROM priority
          WHERE path::text = ANY(${firstLevelPaths})
        `.execute(db);

        for (const fl of firstLevelResult.rows) {
          const group = priorityMap.get(fl.path);
          if (group) {
            group.priorityId = fl.id;
            group.title = fl.title === "Everything" ? "Inbox" : fl.title;
          }
        }

        const appUrl = this.env.APP_ROOT;

        // Generate per-priority AI summaries (same as in-app notifications)
        const priorities = await Promise.all(
          [...priorityMap.values()].map(async (group) => {
            const threadList = group.threads.slice(0, 10);
            const summary = await generateSummary(
              this.env,
              threadList,
              user.name,
              group.title,
              this.userId ?? undefined
            ).catch(() => fallbackSummary(threadList));

            return {
              title: group.title,
              summary,
              url: priorityDeepLinkUrl(appUrl, group.priorityId),
            };
          })
        );

        // Collect unique author names and sum total qualifying note/message count
        const allAuthorNames = new Set<string>();
        let totalNoteCount = 0;
        for (const row of rows) {
          totalNoteCount += row.note_count;
          if (row.author_names) {
            const names = row.author_names.split(",");
            for (const name of names) {
              const trimmed = name.trim();
              if (trimmed) allAuthorNames.add(trimmed);
            }
          }
        }

        // Generate subject line
        const subject = this.formatSubject([...allAuthorNames], totalNoteCount);

        const unsubscribeUrl = emailToken
          ? `${this.env.SITE_ROOT}/unsubscribe?t=${emailToken}`
          : `${this.env.SITE_ROOT}/unsubscribe`;

        // Persist dedup state BEFORE enqueuing. Cloudflare's output gate flushes
        // pending storage writes before releasing any network egress, so if this
        // alarm is evicted between the queue send and a later storage write the
        // retried alarm will still see `lastEmailedUnreadAt` and skip — avoiding
        // duplicate digest emails to the same inbox.
        await this.ctx.storage.put("lastEmailSentAt", Date.now());
        await this.ctx.storage.put("lastEmailedUnreadAt", latestUpdatedAt);

        await this.env.MAIL_QUEUE.send({
          to: [user.email],
          subject,
          email: "notification-digest",
          props: {
            recipientName: user.name,
            priorities,
            appUrl,
            unsubscribeUrl,
          },
        });

        logger.info("Email notification sent", {
          user_id: this.userId ?? undefined,
          thread_count: rows.length,
          priority_count: priorities.length,
        });
      });

      this.retry.reset();
      await this.clearPending();
    } catch (error) {
      // A transient platform blip (DO reset, Hyperdrive drop) must not
      // abandon the digest cycle: keep pendingNotifyTime and re-arm the
      // alarm so this cycle retries. Dedup state (`lastEmailedUnreadAt`,
      // persisted before the queue send) still guards against duplicates.
      if (isTransientAlarmError(error)) {
        this.captureTransientCounter(error);
        const handled = await this.retry.reschedule({
          storage: this.ctx.storage,
          logger,
          error,
          durableObject: "EmailNotify",
          logContext: { user_id: this.userId ?? undefined },
        });
        // On a setAlarm failure the pending window stays set and the next
        // notify() re-arms it via the lost-alarm check in handleNotify.
        if (handled) return;
      }
      logger.error("Error in EmailNotify alarm", error as Error, {
        user_id: this.userId ?? undefined,
      });
      this.captureException(error as Error);
      await this.clearPending();
    }
  }

  private formatSubject(authorNames: string[], totalNoteCount: number): string {
    if (authorNames.length === 0) {
      return "New activity in Plot";
    }
    if (authorNames.length === 1) {
      const name = authorNames[0];
      return totalNoteCount === 1
        ? `${name} sent you a message`
        : `${name} sent you messages`;
    }
    if (authorNames.length === 2) {
      return `${authorNames[0]} and ${authorNames[1]} sent you messages`;
    }
    return `${authorNames[0]}, ${authorNames[1]}, and more sent you messages`;
  }

  private async clearPending(): Promise<void> {
    await this.ctx.storage.delete("pendingNotifyTime");
  }
}
