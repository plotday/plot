import { DurableObject } from "cloudflare:workers";
import { sql } from "kysely";

import { createLogger } from "@plotday/worker-util";

import { type Kysely, withDb } from "../db";
import type { DB } from "../db-types";
import { type Bindings } from "../env";

const FLUSH_INTERVAL_MS = 60_000; // 1 minute
const HOUR_MS = 60 * 60 * 1000;

// Cost safety limits per priority_twist
const COST_LIMIT_4H = 5; // $5 in 4 hours
const COST_LIMIT_30D = 20; // $20 in 30 days

// Execution quota: max invocations per rolling 24h window
const DEFAULT_EXECUTION_LIMIT = 500;

type UsageRow = {
  cost_type: string;
  hour: number; // this is the nearest UTC hour (rounded down)
  amount: number;
};

export class Usage extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private priorityTwistId?: string;
  private isDirty: boolean = false;
  private nextFlushTime: number | null = null;

  static Get(
    env: {
      readonly USAGE: DurableObjectNamespace<Usage>;
    },
    priorityTwistId: string
  ) {
    const usage = env.USAGE.get(env.USAGE.idFromName(priorityTwistId));
    // Note: init() returns void, but we still dispose the RPC result
    // to clean up any RPC resources from crossing the DO boundary
    usage.init(priorityTwistId);
    return usage;
  }

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
    this.loadState();
  }

  public init(priorityTwistId: string) {
    this.priorityTwistId = priorityTwistId;
    this.persistState();
  }

  private getPriorityTwistId() {
    if (!this.priorityTwistId) {
      throw new Error("Usage used before init()");
    }
    return this.priorityTwistId;
  }

  private initializeTable() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS usage (
        cost_type TEXT NOT NULL,
        hour INTEGER NOT NULL,
        amount INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (cost_type, hour)
      )
    `);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS state (
        id INTEGER PRIMARY KEY DEFAULT 1,
        priorityTwistId TEXT,
        isDirty INTEGER DEFAULT 0,
        nextFlushTime INTEGER
      ) STRICT
    `);

    // Migration: Rename priorityAgentId to priorityTwistId for existing DOs
    // This is safe to run multiple times - it will fail silently if column doesn't exist
    try {
      this.sql.exec(`
        ALTER TABLE state RENAME COLUMN priorityAgentId TO priorityTwistId
      `);
    } catch {
      // Column already renamed or never existed, ignore error
    }
  }

  private loadState() {
    const result = this.sql.exec("SELECT * FROM state WHERE id = 1").next();
    if (!result.done && result.value) {
      const row = result.value as {
        priorityTwistId: string | null;
        isDirty: number;
        nextFlushTime: number | null;
      };
      this.priorityTwistId = row.priorityTwistId ?? undefined;
      this.isDirty = row.isDirty === 1;
      this.nextFlushTime = row.nextFlushTime ?? null;
    }
  }

  private persistState() {
    this.sql.exec(
      `INSERT INTO state (id, priorityTwistId, isDirty, nextFlushTime)
       VALUES (1, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         priorityTwistId = excluded.priorityTwistId,
         isDirty = excluded.isDirty,
         nextFlushTime = excluded.nextFlushTime`,
      this.priorityTwistId ?? null,
      this.isDirty ? 1 : 0,
      this.nextFlushTime ?? null
    );
  }

  /**
   * Increment usage for the given cost type by the specified amount.
   * Writes to SQLite (DO-durable storage) on every call — in-memory buffering
   * is unsafe in DOs since they can be evicted between requests.
   */
  spend(costType: string, amount: number) {
    this.getPriorityTwistId();

    const currentHour = this.getCurrentHour();

    this.sql.exec(
      `
        INSERT INTO usage (cost_type, hour, amount)
        VALUES (?, ?, ?)
        ON CONFLICT(cost_type, hour) DO UPDATE SET
          amount = amount + excluded.amount
      `,
      costType,
      currentHour,
      amount
    );

    if (!this.isDirty) {
      this.isDirty = true;
      this.persistState();
    }
    this.scheduleFlush();
  }

  /**
   * Schedule a flush to happen in the future (debounced)
   */
  private scheduleFlush(): void {
    const now = Date.now();

    // If we already have a flush scheduled soon, don't reschedule
    if (this.nextFlushTime && this.nextFlushTime - now < FLUSH_INTERVAL_MS) {
      return;
    }

    this.nextFlushTime = now + FLUSH_INTERVAL_MS;
    this.persistState();
    this.ctx.storage.setAlarm(this.nextFlushTime);
  }

  /**
   * Alarm handler - called when it's time to flush
   */
  async alarm(): Promise<void> {
    this.nextFlushTime = null;
    this.persistState();

    if (this.isDirty) {
      await this.flushToDb();
    }
  }

  /**
   * Flush all usage data to Db
   */
  private async flushToDb(): Promise<void> {
    const currentHour = this.getCurrentHour();

    // Get all usage records
    const usageRecords = Array.from(
      this.sql.exec("SELECT cost_type, hour, amount FROM usage")
    ) as UsageRow[];

    if (usageRecords.length === 0) {
      this.isDirty = false;
      this.persistState();
      return;
    }

    // Group by hour to handle current vs previous hours
    const recordsByHour = new Map<number, UsageRow[]>();
    for (const record of usageRecords) {
      if (!recordsByHour.has(record.hour)) {
        recordsByHour.set(record.hour, []);
      }
      recordsByHour.get(record.hour)!.push(record);
    }

    await withDb(this.env, async (db) => {
      // Process each hour's records
      for (const [hour, records] of recordsByHour.entries()) {
        await this.flushHourToDb(db, hour, records);

        // Delete records from previous hours after successful flush
        if (hour < currentHour) {
          this.sql.exec("DELETE FROM usage WHERE hour = ?", hour);
        }
      }

      this.isDirty = false;
      this.persistState();

      // Check cost limits after successful flush
      await this.checkCostLimit(db);
    });
  }

  /**
   * Check if this twist's usage exceeds cost safety limits.
   * If exceeded, suspend the twist and notify the owner.
   */
  private async checkCostLimit(db: Kysely<DB>): Promise<void> {
    const priorityTwistId = this.getPriorityTwistId();
    const logger = createLogger({
      durable_object: "Usage",
      operation: "checkCostLimit",
      priority_twist_id: priorityTwistId,
    });

    try {
      // Check if already suspended
      const pt = await db
        .selectFrom("priority_twist")
        .select(["suspended_at", "owner_id", "name"])
        .where("id", "=", priorityTwistId)
        .executeTakeFirst();

      if (!pt || pt.suspended_at) {
        return;
      }

      // Aggregate costs for this priority_twist
      const costResult = await sql<{
        cost_4h: number;
        cost_30d: number;
      }>`
        SELECT
          COALESCE(SUM(CASE WHEN u.hour >= DATE_TRUNC('hour', NOW() - INTERVAL '4 hours')
            THEN u.amount * c.amount ELSE 0 END), 0) as cost_4h,
          COALESCE(SUM(u.amount * c.amount), 0) as cost_30d
        FROM usage u
        JOIN cost c ON u.cost_id = c.id
        WHERE u.priority_twist_id = ${priorityTwistId}
          AND u.hour >= DATE_TRUNC('hour', NOW() - INTERVAL '30 days')
      `.execute(db);

      const { cost_4h, cost_30d } = costResult.rows[0] ?? {
        cost_4h: 0,
        cost_30d: 0,
      };

      // Check thresholds
      const exceeds4h = cost_4h >= COST_LIMIT_4H;
      const exceeds30d = cost_30d >= COST_LIMIT_30D;

      if (!exceeds4h && !exceeds30d) {
        return;
      }

      const reason = exceeds4h
        ? `$${cost_4h.toFixed(
            2
          )} in the last 4 hours (limit: $${COST_LIMIT_4H})`
        : `$${cost_30d.toFixed(
            2
          )} in the last 30 days (limit: $${COST_LIMIT_30D})`;

      logger.info("Cost limit exceeded, suspending twist", {
        cost_4h,
        cost_30d,
        reason,
      });

      // Suspend the twist
      await db
        .updateTable("priority_twist")
        .set({ suspended_at: sql`NOW()` })
        .where("id", "=", priorityTwistId)
        .execute();

      // Notify the owner via Help & Feedback activity
      const helpPriority = await db
        .selectFrom("priority")
        .select("id")
        .where("key", "=", `@plot.help-feedback-${pt.owner_id}`)
        .executeTakeFirst();

      if (helpPriority) {
        const activity = await db
          .insertInto("thread")
          .values({
            priority_id: helpPriority.id,
            title: "Twist processing suspended due to high usage",
            created_by: priorityTwistId,
          })
          .returning("id")
          .executeTakeFirstOrThrow();

        await db
          .insertInto("note")
          .values({
            thread_id: activity.id,
            content: `The twist **${pt.name}** was automatically suspended because it exceeded cost safety limits.\n\n**Reason:** ${reason}\n\nTo resume processing, clear the suspension in the database.`,
            created_by: priorityTwistId,
            author_id: priorityTwistId,
          })
          .execute();
      }
    } catch (error) {
      // Cost check failures should not break usage tracking
      logger.error("Failed to check cost limit", error as Error);
    }
  }

  /**
   * Check if this twist has exceeded its execution quota (rolling 24h window).
   * Returns true if within quota, false if exceeded.
   * If exceeded, suspends the twist and notifies the owner.
   */
  async checkExecutionQuota(limit?: number | null): Promise<boolean> {
    const priorityTwistId = this.getPriorityTwistId();
    const effectiveLimit = limit ?? DEFAULT_EXECUTION_LIMIT;
    const logger = createLogger({
      durable_object: "Usage",
      operation: "checkExecutionQuota",
      priority_twist_id: priorityTwistId,
    });

    try {
      // Query local SQLite for invocation count in the last 24 hours
      const cutoff = this.getCurrentHour() - 24 * HOUR_MS;
      const result = this.sql
        .exec(
          `SELECT COALESCE(SUM(amount), 0) as total
           FROM usage
           WHERE cost_type = 'worker:invocation' AND hour >= ?`,
          cutoff
        )
        .next();

      const total = (result.value as { total: number })?.total ?? 0;

      if (total < effectiveLimit) {
        return true;
      }

      logger.info("Execution quota exceeded, suspending twist", {
        total,
        limit: effectiveLimit,
      });

      // Suspend and notify using the same pattern as checkCostLimit
      await withDb(this.env, async (db) => {
        const pt = await db
          .selectFrom("priority_twist")
          .select(["suspended_at", "owner_id", "name"])
          .where("id", "=", priorityTwistId)
          .executeTakeFirst();

        if (!pt || pt.suspended_at) return;

        await db
          .updateTable("priority_twist")
          .set({ suspended_at: sql`NOW()` })
          .where("id", "=", priorityTwistId)
          .execute();

        const helpPriority = await db
          .selectFrom("priority")
          .select("id")
          .where("key", "=", `@plot.help-feedback-${pt.owner_id}`)
          .executeTakeFirst();

        if (helpPriority) {
          const activity = await db
            .insertInto("thread")
            .values({
              priority_id: helpPriority.id,
              title: "Twist processing suspended due to high execution count",
              created_by: priorityTwistId,
            })
            .returning("id")
            .executeTakeFirstOrThrow();

          await db
            .insertInto("note")
            .values({
              thread_id: activity.id,
              content: `The twist **${pt.name}** was automatically suspended because it exceeded the execution quota.\n\n**Reason:** ${total} executions in the last 24 hours (limit: ${effectiveLimit})\n\nTo resume processing, clear the suspension in the database.`,
              created_by: priorityTwistId,
              author_id: priorityTwistId,
            })
            .execute();
        }
      });

      return false;
    } catch (error) {
      // Quota check failures should not block execution
      logger.error("Failed to check execution quota", error as Error);
      return true;
    }
  }

  /**
   * Flush a specific hour's usage to Db
   */
  private async flushHourToDb(
    db: Kysely<DB>,
    hour: number,
    records: UsageRow[]
  ): Promise<void> {
    const priorityTwistId = this.getPriorityTwistId();
    const logger = createLogger({
      durable_object: "Usage",
      operation: "flushHourToDb",
      priority_twist_id: priorityTwistId,
    });

    logger.info("Flushing usage records", {
      row_count: records.length,
      priority_twist_id: priorityTwistId,
      hour: new Date(hour).toISOString(),
    });

    // Get ALL cost types from the database
    const costs = await db
      .selectFrom("cost")
      .select(["id", "name"])
      .execute();

    // Create a set of existing cost names
    const existingCostNames = new Set(costs.map((c) => c.name));

    // Find cost types in records that don't exist in the cost table
    const missingCostNames = records
      .map((r) => r.cost_type)
      .filter((name) => !existingCostNames.has(name));

    // Insert missing cost types with amount 0
    if (missingCostNames.length > 0) {
      const newCosts = missingCostNames.map((name) => ({
        name,
        start: new Date(hour).toISOString(),
        amount: 0,
      }));

      logger.info("Inserting missing cost types", {
        count: newCosts.length,
        cost_names: missingCostNames,
      });

      const insertedCosts = await db
        .insertInto("cost")
        .values(newCosts)
        .onConflict((oc) =>
          oc.columns(["name", "start"]).doUpdateSet((eb) => ({
            amount: eb.ref("excluded.amount"),
          }))
        )
        .returning(["id", "name"])
        .execute();

      // Add newly inserted costs to our costs array
      costs.push(...insertedCosts);
    }

    // Create a map of cost name -> amount from records
    const recordAmountMap = new Map(
      records.map((r) => [r.cost_type, r.amount])
    );

    // Prepare usage records only for cost types that have actual usage
    const usageRows = costs
      .filter((cost) => recordAmountMap.has(cost.name))
      .map((cost) => ({
        priority_twist_id: priorityTwistId,
        hour: new Date(hour).toISOString(),
        cost_id: cost.id,
        amount: recordAmountMap.get(cost.name)!,
      }));

    if (usageRows.length === 0) {
      return;
    }

    // Upsert to database
    const data = await db
      .insertInto("usage")
      .values(usageRows)
      .onConflict((oc) =>
        oc
          .columns(["priority_twist_id", "hour", "cost_id"])
          .doUpdateSet((eb) => ({
            amount: eb.ref("excluded.amount"),
          }))
      )
      .returningAll()
      .execute();

    // Check if rows were actually affected
    if (!data || data.length === 0) {
      logger.error("Upsert succeeded but no rows were returned", {
        expected_row_count: usageRows.length,
        warning:
          "This may indicate a database constraint issue or silent failure",
      });
    }
  }

  /**
   * Get the current hour timestamp (rounded down to the hour boundary)
   */
  private getCurrentHour(): number {
    return Math.floor(Date.now() / HOUR_MS) * HOUR_MS;
  }
}
