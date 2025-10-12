import { DurableObject } from "cloudflare:workers";

import { type Bindings } from "../env";

export class LogSubscriptions extends DurableObject<Bindings> {
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
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS subscriptions (
        agent_root_id TEXT NOT NULL,
        callback_token TEXT NOT NULL,
        PRIMARY KEY (agent_root_id, callback_token)
      )
    `);
    this.sql.exec(`
      CREATE INDEX IF NOT EXISTS idx_subscriptions_agent_root_id
      ON subscriptions(agent_root_id)
    `);
  }

  subscribe(agentRootId: string, callbackToken: string): void {
    this.sql.exec(
      `
      INSERT OR IGNORE INTO subscriptions (agent_root_id, callback_token)
      VALUES (?, ?)
      `,
      agentRootId,
      callbackToken
    );
  }

  unsubscribe(agentRootId: string, callbackToken: string): void {
    this.sql.exec(
      `
      DELETE FROM subscriptions
      WHERE agent_root_id = ? AND callback_token = ?
      `,
      agentRootId,
      callbackToken
    );
  }

  getSubscribers(agentRootId: string): string[] {
    const results = this.sql.exec(
      `
      SELECT callback_token
      FROM subscriptions
      WHERE agent_root_id = ?
      `,
      [agentRootId]
    );

    const tokens: string[] = [];
    for (const row of results) {
      tokens.push(row.callback_token as string);
    }
    return tokens;
  }
}
