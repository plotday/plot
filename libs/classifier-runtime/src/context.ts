import { CompiledQuery, type Kysely } from "kysely";

import type { ClassifierContext, SandboxDb } from "@plotday/classifier";

/**
 * Build a ClassifierContext over a live Kysely handle. In production
 * (Workers), this replaces the eval-side sandbox handle: queries go
 * straight against the live `public.*` schema (no per-run namespace).
 */
export function classifierContextFromDb<DB>(
  db: Kysely<DB>,
  userId: string
): ClassifierContext {
  return {
    db: db as unknown as SandboxDb,
    userId,
    schemaName: "public",
    corpusName: "production",
    async rawQuery(text: string, values?: unknown[]): Promise<{ rows: unknown[] }> {
      const result = await db.executeQuery<unknown>(
        CompiledQuery.raw(text, values ?? [])
      );
      return { rows: result.rows };
    },
  };
}
