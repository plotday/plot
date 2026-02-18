import { DurableObject } from "cloudflare:workers";
import type { Kysely } from "kysely";

import { type DB, createDb } from "../db";
import { rpc } from "../rpc";
import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";

const BATCH_WINDOW_MS = 100;

export class SyncNotify extends DurableObject<Bindings> {
  private db: Kysely<DB>;
  private priorityId: string | null = null;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.db = createDb(env);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/notify" && request.method === "POST") {
      const body = await request.json<{ priorityId: string }>();
      // Store priorityId in memory since ctx.id.name is not set for idFromName
      if (!this.priorityId) {
        this.priorityId = body.priorityId;
        await this.ctx.storage.put("priorityId", body.priorityId);
      }

      // Schedule alarm with batching window (dedup is automatic — same priority = same DO)
      const currentAlarm = await this.ctx.storage.getAlarm();
      if (!currentAlarm) {
        await this.ctx.storage.setAlarm(Date.now() + BATCH_WINDOW_MS);
      }

      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "SyncNotify",
      operation: "alarm",
    });

    // Resolve priorityId
    if (!this.priorityId) {
      const stored = await this.ctx.storage.get<string>("priorityId");
      if (stored) {
        this.priorityId = stored;
      } else {
        logger.error("SyncNotify DO has no stored priorityId");
        return;
      }
    }

    try {
      // Fan out to UserSync DOs for all users with access to this priority
      await this.notifyUsers(logger);

      // Fan out to TwistSync DOs for all active twists on this priority
      await this.notifyTwists(logger);
    } catch (error) {
      // Log but don't fail — SyncRecovery is the safety net
      logger.error("Error in SyncNotify alarm", error as Error, {
        priority_id: this.priorityId,
      });
    }
  }

  private async notifyUsers(logger: ReturnType<typeof createLogger>): Promise<void> {
    let users: Awaited<ReturnType<typeof rpc<"get_users_with_priority_access">>>;
    try {
      users = await rpc(this.db, "get_users_with_priority_access", {
        target_priority_id: this.priorityId!,
      });
    } catch (error) {
      logger.error("Error querying users for priority", error as Error, {
        priority_id: this.priorityId!,
      });
      return;
    }

    // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
    // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
    const userIds = (!users ? [] : Array.isArray(users) ? users : [users]) as unknown as string[];
    if (userIds.length === 0) {
      return;
    }

    const promises = userIds.map(async (userId) => {
      try {
        const userSyncId = this.env.USER_SYNC.idFromName(userId);
        const userSyncDO = this.env.USER_SYNC.get(userSyncId);
        await userSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: userId }),
          })
        );
      } catch (error) {
        logger.error("Error notifying UserSync DO", error as Error, {
          user_id: userId,
          priority_id: this.priorityId!,
        });
      }
    });

    await Promise.allSettled(promises);
  }

  private async notifyTwists(logger: ReturnType<typeof createLogger>): Promise<void> {
    let twists: { id: string }[];
    try {
      twists = await this.db
        .selectFrom("priority_twist")
        .select("id")
        .where("priority_id", "=", this.priorityId!)
        .where("archived_at", "is", null)
        .execute();
    } catch (error) {
      logger.error("Error querying twists for priority", error as Error, {
        priority_id: this.priorityId!,
      });
      return;
    }

    if (!twists || twists.length === 0) {
      return;
    }

    const promises = twists.map(async (twist) => {
      try {
        const twistSyncId = this.env.TWIST_SYNC.idFromName(twist.id);
        const twistSyncDO = this.env.TWIST_SYNC.get(twistSyncId);
        await twistSyncDO.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: twist.id }),
          })
        );
      } catch (error) {
        logger.error("Error notifying TwistSync DO", error as Error, {
          priority_twist_id: twist.id,
          priority_id: this.priorityId!,
        });
      }
    });

    await Promise.allSettled(promises);
  }
}
