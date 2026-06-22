import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";

import { backgroundPressure, recordLatency } from "@plotday/worker-util";

/**
 * Minimal DB type for the classify worker. The cascade calls all of its
 * SQL through ctx.rawQuery (untyped), and the consumer handler only
 * touches thread_priority directly, so we only declare that table here.
 * The api worker maintains the full kysely-codegen type for its needs.
 */
type ThreadPriorityRow = {
  thread_id: string;
  user_id: string;
  priority_id: string | null;
  classify_at: Date | null;
  user_moved: boolean;
  applied_default_channel_id: string | number | null;
  archived_at: Date | null;
};

export type DB = {
  thread_priority: ThreadPriorityRow;
};

export type ClassifyDb = Kysely<DB>;

export { sql };

// PostgreSQL bigint (OID 20) → JS number. Mirror workers/api/src/db.ts so
// channel.id (bigint) survives the round-trip in case any rawQuery
// returns it directly to JS code.
pg.types.setTypeParser(20, (val: string) => parseInt(val, 10));

export function createDb(env: {
  DATABASE_URL?: string;
  HYPERDRIVE?: { connectionString: string };
  HYPERDRIVE_BG?: { connectionString: string };
}): ClassifyDb {
  const connectionString =
    env.HYPERDRIVE_BG?.connectionString ??
    env.HYPERDRIVE?.connectionString ??
    env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("classify-worker: DATABASE_URL or HYPERDRIVE binding required");
  }
  const pool = new pg.Pool({
    connectionString,
    max: 1,
    // Background lane: tight lock_timeout (5s) fast-fails thread_priority /
    // user_sync contention; idle_in_transaction reap matches the api worker so a
    // worker reloaded mid-transaction can't pin a backend for the full
    // statement_timeout.
    options:
      "-c statement_timeout=30000 -c idle_in_transaction_session_timeout=120000 -c lock_timeout=5000",
  });
  pool.on("error", () => {});
  return new Kysely<DB>({ dialect: new PostgresDialect({ pool }) });
}

export async function withDb<T>(
  env: {
    DATABASE_URL?: string;
    HYPERDRIVE?: { connectionString: string };
    HYPERDRIVE_BG?: { connectionString: string };
  },
  fn: (db: ClassifyDb) => Promise<T>
): Promise<T> {
  const db = createDb(env);
  try {
    // Fallback SET in case Hyperdrive reuses a pooled connection past its
    // startup phase (mirrors workers/api/src/db.ts). lock_timeout bounds the
    // wait for a contended row lock so the settle/same UPDATE fast-fails
    // instead of pinning this connection for the full statement_timeout.
    // Time both SETs together as a connection-acquire + backend-responsiveness
    // probe and fold into the shared EWMA. No timeout catch here: 57014 is
    // caught inside the per-message handler loop (never propagates to this
    // level) and will be recorded there in Task 8.
    const startedAt = Date.now();
    await sql`SET statement_timeout = 30000`.execute(db);
    await sql`SET lock_timeout = 5000`.execute(db);
    recordLatency(backgroundPressure, Date.now() - startedAt);
    return await fn(db);
  } finally {
    await db.destroy();
  }
}

/**
 * Row-lock contention surfacing as a canceled statement: pg SQLSTATE 55P03
 * (lock_not_available), raised when a statement set `lock_timeout` and gave up
 * waiting for a row lock. The settle/same UPDATE on thread_priority contends
 * with concurrent per-user writers (reclassify_user_threads, connector syncs,
 * sibling settles) — most often on the per-user singleton user_sync(user_id,
 * 'thread') row that every thread/thread_priority write bumps. That contention
 * is expected and self-healing: classify_at stays set, so the queue retry and
 * the hourly sweep re-enqueue the job to run when the lock is free.
 *
 * Deliberately NARROWER than the api worker's isLockContentionError: it matches
 * only lock_timeout (55P03), NOT statement_timeout (57014) — see
 * isStatementTimeoutError for the latter. Deadlocks (40P01) are also excluded —
 * retryOnTxnConflict owns those.
 */
export function isLockTimeoutError(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "55P03") return true;
  const msg = ((error as Error | null)?.message ?? "").toLowerCase();
  return msg.includes("canceling statement due to lock timeout");
}

/**
 * A statement hit the 30s statement_timeout: pg SQLSTATE 57014
 * (query_canceled). With lock_timeout=5s in place (isLockTimeoutError), a 57014
 * means the statement genuinely ran 30s WITHOUT waiting on a row lock.
 *
 * For the classify worker this is NOT a slow query: every scoring-stage query
 * is <120ms warm in prod even for the largest training set (verified against
 * the mega-user — bitmap-indexed training fetch ~35ms, facet gate ~50ms). A
 * 57014 here is transient DB backend SATURATION during a reclassification
 * burst: many of one user's threads go pending at once (an hourly sweep of up
 * to 1000 rows + queue retries + that user's own heavy app traffic), the
 * backend saturates, and a normally-fast query balloons past 30s.
 *
 * It is self-healing and must NOT be hammered: retrying the same job
 * immediately just re-loads the already-overloaded backend (the captured burst
 * is exactly this — PostHog 019ed53e). The consumer instead captures it once
 * for visibility and ACKs the message; classify_at stays set, so the next
 * hourly sweep re-enqueues the job to run when contention has cleared. Matched
 * by SQLSTATE or message so it works whether or not the driver attached `code`.
 */
export function isStatementTimeoutError(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "57014") return true;
  const msg = ((error as Error | null)?.message ?? "").toLowerCase();
  return msg.includes("canceling statement due to statement timeout");
}
