import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";

const MONTH_MS = 30 * 24 * 60 * 60 * 1000;

export class UserAiUsage extends DurableObject<Bindings> {
  private sql: SqlStorage;
  private userId?: string;

  static Get(
    env: {
      readonly USER_AI_USAGE: DurableObjectNamespace<UserAiUsage>;
    },
    userId: string
  ) {
    const stub = env.USER_AI_USAGE.get(
      env.USER_AI_USAGE.idFromName(userId)
    );
    stub.init(userId);
    return stub;
  }

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
    this.loadState();
  }

  public init(userId: string) {
    this.userId = userId;
    this.persistState();
  }

  private initializeTable() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS ai_usage (
        operation TEXT NOT NULL,
        month INTEGER NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (operation, month)
      )
    `);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS state (
        id INTEGER PRIMARY KEY DEFAULT 1,
        userId TEXT
      ) STRICT
    `);
  }

  private loadState() {
    const result = this.sql.exec("SELECT * FROM state WHERE id = 1").next();
    if (!result.done && result.value) {
      const row = result.value as { userId: string | null };
      this.userId = row.userId ?? undefined;
    }
  }

  private persistState() {
    this.sql.exec(
      `INSERT INTO state (id, userId)
       VALUES (1, ?)
       ON CONFLICT(id) DO UPDATE SET userId = excluded.userId`,
      this.userId ?? null
    );
  }

  private getCurrentMonth(): number {
    return Math.floor(Date.now() / MONTH_MS);
  }

  /**
   * Increment usage count for an operation. Returns the new total.
   */
  increment(operation: string, count = 1): number {
    const month = this.getCurrentMonth();

    this.sql.exec(
      `INSERT INTO ai_usage (operation, month, count)
       VALUES (?, ?, ?)
       ON CONFLICT(operation, month) DO UPDATE SET
         count = count + excluded.count`,
      operation,
      month,
      count
    );

    const result = this.sql
      .exec(
        "SELECT count FROM ai_usage WHERE operation = ? AND month = ?",
        operation,
        month
      )
      .next();

    return (result.value as { count: number })?.count ?? count;
  }

  /**
   * Check if an operation is within its limit.
   */
  check(
    operation: string,
    limit: number
  ): { allowed: boolean; remaining: number } {
    const month = this.getCurrentMonth();

    const result = this.sql
      .exec(
        "SELECT count FROM ai_usage WHERE operation = ? AND month = ?",
        operation,
        month
      )
      .next();

    const current = (result.value as { count: number })?.count ?? 0;
    const remaining = Math.max(0, limit - current);

    return { allowed: current < limit, remaining };
  }

  /**
   * Get all usage counts for the current month.
   */
  getUsage(): Record<string, number> {
    const month = this.getCurrentMonth();

    const rows = Array.from(
      this.sql.exec(
        "SELECT operation, count FROM ai_usage WHERE month = ?",
        month
      )
    ) as Array<{ operation: string; count: number }>;

    const usage: Record<string, number> = {};
    for (const row of rows) {
      usage[row.operation] = row.count;
    }
    return usage;
  }
}
