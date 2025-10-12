import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";

export class Storage extends DurableObject {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private initializeTable() {
    try {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS store (
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (key)
        )
      `);
    } catch (error) {
      console.error("Store table initialization error:", error);
      throw error;
    }
  }

  get(key: string): string | null {
    try {
      const result = this.sql
        .exec("SELECT value FROM store WHERE key = ?", [key])
        .next();
      if (result.done) {
        return null;
      }
      return result.value.value as string;
    } catch (error) {
      console.error("Store get error:", error);
      throw error;
    }
  }

  set(key: string, value: string): void {
    this.sql.exec(
      `
          INSERT INTO store (key, value) 
          VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET 
            value = excluded.value
        `,
      key,
      value
    );
  }

  clear(key: string) {
    this.sql.exec("DELETE FROM store WHERE key = ?", key);
  }

  clearAll() {
    this.sql.exec("DELETE FROM store");
  }
}
