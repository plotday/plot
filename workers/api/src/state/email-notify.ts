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

export class EmailNotify extends DurableObject<Bindings> {
  private userId: string | null = null;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
  }

  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, undefined, {
      durable_object: "EmailNotify",
      user_id: this.userId ?? undefined,
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
    if (!this.userId) {
      this.userId = userId;
      await this.ctx.storage.put("userId", userId);
    }

    const pendingNotifyTime =
      (await this.ctx.storage.get<number>("pendingNotifyTime")) ?? 0;

    if (pendingNotifyTime > 0) {
      // Already have a pending alarm — keep the earlier one for batching
      return;
    }

    const now = Date.now();
    await this.ctx.storage.put("pendingNotifyTime", now);

    const multiplier = parseFloat(this.env.NOTIFICATION_DELAY_MULTIPLIER ?? "1.0");
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
      // Check if user has been active since the notification
      const broadcastId = this.env.BROADCAST.idFromName(this.userId);
      const broadcast = this.env.BROADCAST.get(broadcastId);
      const broadcastResponse = await broadcast.fetch(
        new Request("http://do/last-active")
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
        const threadsResult = await sql<{
          thread_id: string;
          thread_title: string | null;
          thread_preview: string | null;
          thread_updated_at: string;
          priority_id: string;
          priority_path: string;
          priority_title: string;
        }>`
          SELECT
            t.id::text AS thread_id,
            t.title AS thread_title,
            t.preview AS thread_preview,
            tu.updated_at::text AS thread_updated_at,
            p.id::text AS priority_id,
            p.path::text AS priority_path,
            p.title AS priority_title
          FROM thread_unread tu
          JOIN thread t ON t.id = tu.thread_id
          JOIN priority p ON p.id = t.priority_id
          WHERE tu.user_id = ${this.userId!}::uuid
            AND tu.read_at IS NULL
            AND tu.urgency != 'passive'
            AND t.archived_at IS NULL
            AND (t.draft = false OR t.created_by = ${this.userId!}::uuid)
            AND (
              t.access = 'public'
              OR t.created_by = ${this.userId!}::uuid
              OR (t.access = 'members' AND "user".get_effective_role(${this.userId!}::uuid, t.priority_id) = 'member')
              OR "user".user_contact_id(${this.userId!}::uuid) = ANY(t.access_contacts)
            )
          ORDER BY tu.updated_at DESC
        `.execute(db);

        if (threadsResult.rows.length === 0) {
          logger.info("Skipping email — no unread threads", {
            user_id: this.userId ?? undefined,
          });
          await this.clearPending();
          return;
        }

        // Dedup: check if there are new unreads since last email
        const latestUpdatedAt = threadsResult.rows[0].thread_updated_at;
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

        for (const row of threadsResult.rows) {
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
            group.title = fl.title;
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
              group.title
            ).catch(() => fallbackSummary(threadList));

            const shortId = uuidToBase58(group.priorityId);
            return {
              title: group.title,
              summary,
              url: `${appUrl}/${shortId}?tab=activity`,
            };
          })
        );

        // Generate subject line
        const subject = this.formatSubject(priorities.map((p) => p.title));

        // Enqueue email
        await this.env.MAIL_QUEUE.send({
          to: [user.email],
          subject,
          email: "notification-digest",
          props: {
            recipientName: user.name,
            priorities,
            appUrl,
          },
        });

        // Update state
        await this.ctx.storage.put("lastEmailSentAt", Date.now());
        await this.ctx.storage.put("lastEmailedUnreadAt", latestUpdatedAt);

        logger.info("Email notification sent", {
          user_id: this.userId ?? undefined,
          thread_count: threadsResult.rows.length,
          priority_count: priorities.length,
        });
      });
    } catch (error) {
      logger.error("Error in EmailNotify alarm", error as Error, {
        user_id: this.userId ?? undefined,
      });
      this.captureException(error as Error);
    } finally {
      await this.clearPending();
    }
  }

  private formatSubject(priorityTitles: string[]): string {
    if (priorityTitles.length === 0) return "New activity in Plot";
    if (priorityTitles.length === 1) return `Activity in ${priorityTitles[0]}`;
    if (priorityTitles.length === 2)
      return `Activity in ${priorityTitles[0]} and ${priorityTitles[1]}`;
    const last = priorityTitles[priorityTitles.length - 1];
    const rest = priorityTitles.slice(0, -1).join(", ");
    return `Activity in ${rest}, and ${last}`;
  }

  private async clearPending(): Promise<void> {
    await this.ctx.storage.delete("pendingNotifyTime");
  }
}
