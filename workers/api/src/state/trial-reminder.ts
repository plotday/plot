import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { withDb } from "../db";
import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import {
  addTrialNote,
  buildReminderContent,
  expireTrial,
  getExcessConnectionNames,
  getExcessTwistNames,
  getPlotTwistInstanceId,
} from "../utils/trial";

type NextAction = "7day" | "2day" | "expire" | "done";

const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const TWO_DAYS_MS = 2 * 24 * 60 * 60 * 1000;

export class TrialReminder extends DurableObject<Bindings> {
  private userId: string | null = null;
  private trialThreadId: string | null = null;
  private trialEndsAt: number | null = null;
  private nextAction: NextAction = "done";

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.userId = (await ctx.storage.get<string>("userId")) ?? null;
      this.trialThreadId =
        (await ctx.storage.get<string>("trialThreadId")) ?? null;
      this.trialEndsAt =
        (await ctx.storage.get<number>("trialEndsAt")) ?? null;
      this.nextAction =
        (await ctx.storage.get<NextAction>("nextAction")) ?? "done";
    });
  }

  private captureException(
    error: Error,
    properties?: Record<string, unknown>
  ) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, undefined, {
      durable_object: "TrialReminder",
      user_id: this.userId ?? undefined,
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/start" && request.method === "POST") {
      const body = await request.json<{
        userId: string;
        trialThreadId: string;
        trialEndsAt: number;
      }>();

      this.userId = body.userId;
      this.trialThreadId = body.trialThreadId;
      this.trialEndsAt = body.trialEndsAt;

      await this.ctx.storage.put("userId", body.userId);
      await this.ctx.storage.put("trialThreadId", body.trialThreadId);
      await this.ctx.storage.put("trialEndsAt", body.trialEndsAt);

      // Determine first alarm based on time remaining
      const now = Date.now();
      const timeRemaining = body.trialEndsAt - now;

      if (timeRemaining <= 0) {
        // Trial already expired (shouldn't happen, but handle gracefully)
        this.nextAction = "expire";
        await this.ctx.storage.put("nextAction", "expire");
        await this.ctx.storage.setAlarm(now + 1000); // Run immediately
      } else if (timeRemaining <= TWO_DAYS_MS) {
        // Less than 2 days — skip to 2-day reminder
        this.nextAction = "2day";
        await this.ctx.storage.put("nextAction", "2day");
        await this.ctx.storage.setAlarm(now + 1000);
      } else if (timeRemaining <= SEVEN_DAYS_MS) {
        // Less than 7 days — skip to 7-day reminder
        this.nextAction = "7day";
        await this.ctx.storage.put("nextAction", "7day");
        await this.ctx.storage.setAlarm(now + 1000);
      } else {
        // Schedule 7-day reminder
        this.nextAction = "7day";
        await this.ctx.storage.put("nextAction", "7day");
        await this.ctx.storage.setAlarm(body.trialEndsAt - SEVEN_DAYS_MS);
      }

      return new Response("OK", { status: 200 });
    }

    if (url.pathname === "/cancel" && request.method === "POST") {
      this.nextAction = "done";
      await this.ctx.storage.put("nextAction", "done");
      await this.ctx.storage.deleteAlarm();
      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "TrialReminder",
      operation: "alarm",
      user_id: this.userId ?? undefined,
    });

    if (
      !this.userId ||
      !this.trialThreadId ||
      !this.trialEndsAt ||
      this.nextAction === "done"
    ) {
      return;
    }

    try {
      await withDb(this.env, async (db) => {
        // Check if user is still on trial
        const sub = await db
          .selectFrom("user_subscription")
          .select(["plan", "trial_ends_at", "stripe_customer_id"])
          .where("user_id", "=", this.userId!)
          .executeTakeFirst();

        if (!sub || sub.plan !== "core" || !sub.trial_ends_at) {
          // User already upgraded or was downgraded
          logger.info("User no longer on trial, stopping reminders", {
            user_id: this.userId ?? undefined,
          });
          this.nextAction = "done";
          await this.ctx.storage.put("nextAction", "done");
          return;
        }

        const siteRoot = this.env.SITE_ROOT || "https://plot.day";

        // Look up the Plot twist covering the trial thread's priority
        const plotApp = await db
          .selectFrom("thread_priority")
          .select("priority_id")
          .where("thread_id", "=", this.trialThreadId!)
          .where("user_id", "=", this.userId!)
          .executeTakeFirst();
        const plotTwistInstanceId = plotApp
          ? await getPlotTwistInstanceId(db, plotApp.priority_id)
          : null;

        switch (this.nextAction) {
          case "7day": {
            const excessConnections = await getExcessConnectionNames(
              db,
              this.userId!
            );
            const excessTwists = await getExcessTwistNames(db, this.userId!);
            const content = buildReminderContent(
              7,
              excessConnections,
              excessTwists,
              siteRoot
            );

            await addTrialNote(
              db,
              this.trialThreadId!,
              this.userId!,
              content,
              "reminder-7day",
              true,
              plotTwistInstanceId
            );

            // Notify sync
            await this.notifyPrioritySync(db);

            // Schedule 2-day reminder
            this.nextAction = "2day";
            await this.ctx.storage.put("nextAction", "2day");
            await this.ctx.storage.setAlarm(this.trialEndsAt! - TWO_DAYS_MS);

            logger.info("Sent 7-day trial reminder", {
              user_id: this.userId ?? undefined,
            });
            break;
          }

          case "2day": {
            const excessConnections = await getExcessConnectionNames(
              db,
              this.userId!
            );
            const excessTwists = await getExcessTwistNames(db, this.userId!);
            const content = buildReminderContent(
              2,
              excessConnections,
              excessTwists,
              siteRoot
            );

            await addTrialNote(
              db,
              this.trialThreadId!,
              this.userId!,
              content,
              "reminder-2day",
              true,
              plotTwistInstanceId
            );

            // Notify sync
            await this.notifyPrioritySync(db);

            // Schedule expiry
            this.nextAction = "expire";
            await this.ctx.storage.put("nextAction", "expire");
            await this.ctx.storage.setAlarm(this.trialEndsAt!);

            logger.info("Sent 2-day trial reminder", {
              user_id: this.userId ?? undefined,
            });
            break;
          }

          case "expire": {
            await expireTrial(
              db,
              this.env,
              this.userId!,
              sub.stripe_customer_id
            );

            this.nextAction = "done";
            await this.ctx.storage.put("nextAction", "done");

            logger.info("Trial expired, user downgraded", {
              user_id: this.userId ?? undefined,
            });
            break;
          }
        }
      });
    } catch (error) {
      if (
        error instanceof Error &&
        error.message.includes("storage operation exceeded timeout")
      ) {
        logger.warn("TrialReminder alarm interrupted by DO storage timeout", {
          user_id: this.userId ?? undefined,
        });
        return;
      }
      logger.error("Error in TrialReminder alarm", error as Error, {
        user_id: this.userId ?? undefined,
      });
      this.captureException(error as Error);
    }
  }

  /**
   * Notify sync for the @plot.app priority so the app picks up new notes.
   */
  private async notifyPrioritySync(db: any): Promise<void> {
    const plotApp = await db
      .selectFrom("priority")
      .select("id")
      .where("key", "=", "@plot.app")
      .executeTakeFirst();

    if (plotApp) {
      try {
        const syncNotifyId = this.env.SYNC_NOTIFY.idFromName(plotApp.id);
        const syncNotifyDO = this.env.SYNC_NOTIFY.get(syncNotifyId);
        await syncNotifyDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: plotApp.id }),
          })
        );
      } catch {
        // Non-blocking
      }
    }
  }
}
