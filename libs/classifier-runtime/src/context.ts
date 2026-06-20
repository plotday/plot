import { CompiledQuery, type Kysely } from "kysely";

import type {
  ClassifierBatchCache,
  ClassifierContext,
  SandboxDb,
} from "@plotday/classifier";

/**
 * Build a ClassifierContext over a live Kysely handle. In production
 * (Workers), this replaces the eval-side sandbox handle: queries go
 * straight against the live `public.*` schema (no per-run namespace).
 *
 * Pass a `batchCache` (one `Map` per classify queue batch, or per foreground
 * classify) to deduplicate user-scoped, batch-stable reads across candidates —
 * see `cachedUserRead`. Omit it for one-off contexts where memoization buys
 * nothing.
 */
export function classifierContextFromDb<DB>(
  db: Kysely<DB>,
  userId: string,
  batchCache?: ClassifierBatchCache
): ClassifierContext {
  return {
    db: db as unknown as SandboxDb,
    userId,
    schemaName: "public",
    corpusName: "production",
    batchCache,
    async rawQuery(text: string, values?: unknown[]): Promise<{ rows: unknown[] }> {
      const result = await db.executeQuery<unknown>(
        CompiledQuery.raw(text, values ?? [])
      );
      return { rows: result.rows };
    },
  };
}
