#!/usr/bin/env tsx
/**
 * Append a set of curated prod threads to an existing corpus as new cases.
 *
 * Unlike `from-prod.ts` (which rebuilds the whole corpus, preserving labels),
 * this script appends specific thread UUIDs to cases.yaml: each is hydrated
 * via the shared extraction module, anonymized with the same deterministic
 * pipeline, and any newly-referenced contacts/groups/connections/embeddings
 * are backfilled into world.yaml / embeddings.yaml. Existing case ids, gold
 * labels, and rationale text are preserved untouched. The leak check runs
 * over every modified document before anything is written.
 *
 * Requires a schema v2 corpus (run from-prod first for v1 corpora).
 *
 * Usage:
 *   pnpm exec tsx src/seeder/add-prod-cases.ts --corpus kris \
 *     --threads 019e0e03-6ce9-...,019e0797-5397-...,...
 */
import { parseArgs } from "node:util";

import { appendProdThreads } from "./append";

const DEFAULT_DB_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

async function main() {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      threads: { type: "string" },
      "db-url": { type: "string" },
      "allow-note-embeddings": { type: "boolean" },
    },
  });
  if (!values.corpus || !values.threads) {
    console.error(
      "Usage: add-prod-cases --corpus <name> --threads <uuid1,uuid2,...> [--db-url <url>] [--allow-note-embeddings]"
    );
    process.exit(2);
  }
  await appendProdThreads({
    corpus: values.corpus,
    threadIds: values.threads
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    mode: { kind: "cases" },
    dbUrl: values["db-url"] ?? DEFAULT_DB_URL,
    // note-content vectors are own-data-only; kris keeps them by default.
    allowNoteContentEmbeddings:
      values["allow-note-embeddings"] ?? values.corpus === "kris",
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
