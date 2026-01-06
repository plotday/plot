import { DurableObject } from "cloudflare:workers";

import { type SupabaseClient, createClient } from "@plotday/db";

import { type Bindings } from "../env";
import { createLogger } from "../utils/logger";

const FLUSH_INTERVAL_MS = 60_000; // 1 minute
const HOUR_MS = 60 * 60 * 1000;

type UsageRow = {
  cost_type: string;
  hour: number; // this is the nearest UTC hour (rounded down)
  amount: number;
};

export class Usage extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private supabase: SupabaseClient;
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
    usage.init(priorityTwistId);
    return usage;
  }

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.supabase = createClient(
      this.env.SUPABASE_URL,
      this.env.SUPABASE_SERVICE_KEY
    );
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
   * Increment usage for the given cost type by the specified amount
   */
  spend(costType: string, amount: number) {
    this.getPriorityTwistId();

    const currentHour = this.getCurrentHour();

    // Check if we've rolled over to a new hour
    const previousHourResult = this.sql
      .exec("SELECT DISTINCT hour FROM usage WHERE hour < ? LIMIT 1", [
        currentHour,
      ])
      .next();

    if (!previousHourResult.done) {
      // We have data from a previous hour, flush it before continuing
      // Note: flushToSupabase is async but we can't await it here
      // It will handle errors internally
      this.flushToSupabase();
    }

    // Insert or update the current hour's usage
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

    this.isDirty = true;
    this.persistState();
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
      await this.flushToSupabase();
    }
  }

  /**
   * Flush all usage data to Supabase
   */
  private async flushToSupabase(): Promise<void> {
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

    // Process each hour's records
    for (const [hour, records] of recordsByHour.entries()) {
      await this.flushHourToSupabase(hour, records);

      // Delete records from previous hours after successful flush
      if (hour < currentHour) {
        this.sql.exec("DELETE FROM usage WHERE hour = ?", hour);
      }
    }

    this.isDirty = false;
    this.persistState();
  }

  /**
   * Flush a specific hour's usage to Supabase
   */
  private async flushHourToSupabase(
    hour: number,
    records: UsageRow[]
  ): Promise<void> {
    const priorityTwistId = this.getPriorityTwistId();
    const logger = createLogger({
      durable_object: "Usage",
      operation: "flushHourToSupabase",
      priority_twist_id: priorityTwistId,
    });

    logger.info("Flushing usage records", {
      row_count: records.length,
      priority_twist_id: priorityTwistId,
      hour: new Date(hour).toISOString(),
    });

    // Get ALL cost types from the database
    const { data: costs, error: costsError } = await this.supabase
      .from("cost")
      .select("id, name");

    if (costsError || !costs) {
      logger.error("Failed to fetch costs", costsError as Error);
      throw new Error(`Failed to fetch costs: ${costsError?.message}`);
    }

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

      const { data: insertedCosts, error: insertError } = await this.supabase
        .from("cost")
        .upsert(newCosts, { onConflict: "name,start", ignoreDuplicates: false })
        .select("id, name");

      if (insertError) {
        logger.error("Failed to insert missing costs", insertError as Error, {
          cost_names: missingCostNames,
        });
        throw new Error(
          `Failed to insert missing costs: ${insertError.message}`
        );
      }

      // Add newly inserted costs to our costs array
      if (insertedCosts) {
        costs.push(...insertedCosts);
      }
    }

    // Create a map of cost name -> amount from records
    const recordAmountMap = new Map(
      records.map((r) => [r.cost_type, r.amount])
    );

    // Prepare usage records for ALL cost types, using 0 for missing ones
    const usageRows = costs.map((cost) => {
      const amount = recordAmountMap.get(cost.name) ?? 0;

      return {
        priority_twist_id: priorityTwistId,
        hour: new Date(hour).toISOString(),
        cost_id: cost.id,
        amount,
      };
    });

    if (usageRows.length === 0) {
      return;
    }

    // Upsert to Supabase - use .select() to get affected rows
    const { data, error: upsertError } = await this.supabase
      .from("usage")
      .upsert(usageRows, {
        onConflict: "priority_twist_id,hour,cost_id",
        ignoreDuplicates: false,
      })
      .select();

    if (upsertError) {
      logger.error("Failed to upsert usage", upsertError as Error, {
        row_count: usageRows.length,
      });
      throw new Error(`Failed to upsert usage: ${upsertError.message}`);
    }

    // Check if rows were actually affected
    if (!data || data.length === 0) {
      logger.error("Upsert succeeded but no rows were returned", {
        expected_row_count: usageRows.length,
        warning: "This may indicate a database constraint issue or silent failure",
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
