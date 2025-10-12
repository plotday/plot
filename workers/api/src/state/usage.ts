import { DurableObject } from "cloudflare:workers";

import { type SupabaseClient, createClient } from "@plotday/db";

import { type Bindings } from "../env";

const FLUSH_INTERVAL_MS = 60_000; // 1 minute
const HOUR_MS = 60 * 60 * 1000;

type UsageRow = {
  cost_type: string;
  hour: number;
  amount: number;
};

export class Usage extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private supabase: SupabaseClient;
  private priorityAgentId: string;
  private isDirty: boolean = false;
  private nextFlushTime: number | null = null;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.supabase = createClient(
      this.env.SUPABASE_URL,
      this.env.SUPABASE_SERVICE_KEY
    );
    // Extract priorityAgentId from the Durable Object ID
    this.priorityAgentId = ctx.id.toString();
    this.initializeTable();
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
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
  }

  /**
   * Increment usage for the given cost type by the specified amount
   */
  spend(costType: string, amount: number): void {
    const currentHour = this.getCurrentHour();

    // Check if we've rolled over to a new hour
    const previousHourResult = this.sql
      .exec(
        "SELECT DISTINCT hour FROM usage WHERE hour < ? LIMIT 1",
        [currentHour]
      )
      .next();

    if (!previousHourResult.done) {
      // We have data from a previous hour, flush it before continuing
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
    this.ctx.storage.setAlarm(this.nextFlushTime);
  }

  /**
   * Alarm handler - called when it's time to flush
   */
  async alarm(): Promise<void> {
    this.nextFlushTime = null;

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
  }

  /**
   * Flush a specific hour's usage to Supabase
   */
  private async flushHourToSupabase(
    hour: number,
    records: UsageRow[]
  ): Promise<void> {
    // Get cost IDs for all cost types
    const costTypes = [...new Set(records.map((r) => r.cost_type))];
    const { data: costs, error: costsError } = await this.supabase
      .from("cost")
      .select("id, name")
      .in("name", costTypes);

    if (costsError || !costs) {
      console.error("Failed to fetch costs:", costsError);
      throw new Error(`Failed to fetch costs: ${costsError?.message}`);
    }

    // Create a map of cost name -> cost id
    const costIdMap = new Map(costs.map((c) => [c.name, c.id]));

    // Prepare usage records for upsert
    const usageRows = records
      .map((record) => {
        const costId = costIdMap.get(record.cost_type);
        if (!costId) {
          console.warn(`Cost type "${record.cost_type}" not found in database`);
          return null;
        }

        return {
          priority_agent_id: this.priorityAgentId,
          date: new Date(hour).toISOString(),
          cost_id: costId,
          amount: record.amount,
        };
      })
      .filter((r) => r !== null);

    if (usageRows.length === 0) {
      return;
    }

    // Upsert to Supabase
    const { error: upsertError } = await this.supabase
      .from("usage")
      .upsert(usageRows, {
        onConflict: "priority_agent_id,date,cost_id",
        ignoreDuplicates: false,
      });

    if (upsertError) {
      console.error("Failed to upsert usage:", upsertError);
      throw new Error(`Failed to upsert usage: ${upsertError.message}`);
    }
  }

  /**
   * Get the current hour timestamp (rounded down to the hour)
   */
  private getCurrentHour(): number {
    return Math.floor(Date.now() / HOUR_MS) * HOUR_MS;
  }
}
