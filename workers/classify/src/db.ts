import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";

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

export function createDb(env: { DATABASE_URL?: string; HYPERDRIVE?: { connectionString: string } }): ClassifyDb {
  const connectionString = env.HYPERDRIVE?.connectionString ?? env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("classify-worker: DATABASE_URL or HYPERDRIVE binding required");
  }
  const pool = new pg.Pool({
    connectionString,
    max: 1,
    options: "-c statement_timeout=30000",
  });
  pool.on("error", () => {
    // Swallow pool-level errors; query errors propagate via promise rejection.
  });
  return new Kysely<DB>({ dialect: new PostgresDialect({ pool }) });
}

export async function withDb<T>(
  env: { DATABASE_URL?: string; HYPERDRIVE?: { connectionString: string } },
  fn: (db: ClassifyDb) => Promise<T>
): Promise<T> {
  const db = createDb(env);
  try {
    await sql`SET statement_timeout = 30000`.execute(db);
    return await fn(db);
  } finally {
    await db.destroy();
  }
}
