import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";

export type SessionData = {
  token: string;
  userId: string;
  email: string;
};

export class SdkTokenStore extends DurableObject {
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
        CREATE TABLE IF NOT EXISTS sessions (
          session_id TEXT PRIMARY KEY,
          token TEXT NOT NULL,
          user_id TEXT NOT NULL,
          email TEXT NOT NULL,
          expires_at INTEGER NOT NULL
        )
      `);
      this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_sessions_expires_at
        ON sessions(expires_at)
      `);
    } catch (error) {
      console.error("SdkTokenStore table initialization error:", error);
      throw error;
    }
  }

  set(sessionId: string, data: SessionData): void {
    const expiresAt = Date.now() + 5 * 60 * 1000; // 5 minutes from now

    this.sql.exec(
      `
        INSERT INTO sessions (session_id, token, user_id, email, expires_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
          token = excluded.token,
          user_id = excluded.user_id,
          email = excluded.email,
          expires_at = excluded.expires_at
      `,
      sessionId,
      data.token,
      data.userId,
      data.email,
      expiresAt
    );

    // Update alarm to clean up expired sessions
    this.updateAlarm();
  }

  get(sessionId: string): SessionData | null {
    try {
      const result = this.sql
        .exec(
          "SELECT token, user_id, email, expires_at FROM sessions WHERE session_id = ?",
          [sessionId]
        )
        .next();

      if (result.done) {
        return null;
      }

      const row = result.value as {
        token: string;
        user_id: string;
        email: string;
        expires_at: number;
      };

      // Check if expired
      if (row.expires_at < Date.now()) {
        this.delete(sessionId);
        return null;
      }

      return {
        token: row.token,
        userId: row.user_id,
        email: row.email,
      };
    } catch (error) {
      console.error("SdkTokenStore get error:", error);
      throw error;
    }
  }

  delete(sessionId: string): void {
    this.sql.exec("DELETE FROM sessions WHERE session_id = ?", sessionId);
    this.updateAlarm();
  }

  private updateAlarm(): void {
    // Find the next session that will expire
    const alarmResult = this.sql
      .exec(
        `
          SELECT expires_at
          FROM sessions
          WHERE expires_at > ?
          ORDER BY expires_at ASC
          LIMIT 1
        `,
        [Date.now()]
      )
      .next();

    if (alarmResult.done) {
      // No more sessions, delete any existing alarm
      this.ctx.storage.deleteAlarm();
    } else {
      const nextExpiresAt = alarmResult.value.expires_at as number;
      this.ctx.storage.setAlarm(nextExpiresAt);
    }
  }

  async alarm(): Promise<void> {
    // Delete all expired sessions
    const now = Date.now();
    this.sql.exec(
      "DELETE FROM sessions WHERE expires_at <= ?",
      now
    );

    // Set the next alarm if there are more sessions
    this.updateAlarm();
  }
}
