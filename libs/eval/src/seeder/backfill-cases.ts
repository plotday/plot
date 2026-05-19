#!/usr/bin/env tsx
/**
 * Backfill `author` and `embedding_ref` on every case in a corpus's
 * cases.yaml by re-querying the prod DB.
 *
 * Mirrors backfill-trainings.ts but operates on candidate.author /
 * candidate.embedding_ref instead of training threads. Preserves all
 * hand-curated state (gold labels, expected, expected_stage, notes, etc.).
 *
 * Usage:
 *   pnpm tsx src/seeder/backfill-cases.ts --corpus kris
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import pg from "pg";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";

import { hashShort } from "./anonymize";

const PROD_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

type CliOpts = { corpus: string };

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: { corpus: { type: "string" } },
  });
  if (!values.corpus) {
    console.error("Usage: backfill-cases --corpus <name>");
    process.exit(2);
  }
  return { corpus: values.corpus };
}

type ThreadRow = {
  id: string;
  embedding_text: string | null;
  note_embedding_text: string | null;
  note_author_id: string | null;
  created_by: string;
};

async function main() {
  const opts = parseOpts();
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = resolve(scriptDir, "..", "..", "corpora", opts.corpus);
  const worldPath = join(corpusDir, "world.yaml");
  const casesPath = join(corpusDir, "cases.yaml");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const world = parseYaml(await readFile(worldPath, "utf-8")) as any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const casesDoc = parseYaml(await readFile(casesPath, "utf-8")) as any;

  const userId: string = world.user.id;

  const contactSlugById = new Map<string, string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.contacts ?? []).map((c: any) => [c.id, c.slug])
  );
  const embRefs = new Set<string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.embeddings ?? []).map((e: any) => e.ref as string)
  );

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const cases = (casesDoc.cases ?? []) as any[];

  // Derive each case's source thread UUID from the case id prefix
  // (NNN-<first 8 hex of thread uuid>). Cases were originally seeded with
  // ids of that shape; fall back to skipping when the prefix doesn't
  // resolve to a known thread.
  const prefixMatch = (id: string) =>
    /^\d+-([0-9a-fA-F]{8})(?:-([0-9a-fA-F-]+))?$/.exec(id);

  const prefixes = new Set<string>();
  for (const c of cases) {
    const m = prefixMatch(c.id);
    if (m) prefixes.add(m[1]!);
  }
  if (prefixes.size === 0) {
    console.error("No cases match the expected id shape NNN-<hex8>; nothing to backfill.");
    process.exit(0);
  }

  const client = new pg.Client({ connectionString: PROD_URL });
  await client.connect();
  let updatedAuthor = 0;
  let updatedEmbedding = 0;
  let skipped = 0;
  try {
    // Pull every thread whose id begins with any of our prefixes for this
    // user. UUIDs cast to text and `LIKE 'prefix%'` (no leading wildcard)
    // hits the btree index. Build one OR'd LIKE clause to fetch all
    // prefixes in a single round-trip.
    const likeClauses = [...prefixes]
      .map((p) => `t.id::text LIKE '${p}%'`)
      .join(" OR ");
    const sql = `SELECT t.id,
                        t.embedding::text AS embedding_text,
                        (
                          SELECT n.embedding::text
                            FROM public.note n
                           WHERE n.thread_id = t.id
                             AND n.archived_at IS NULL
                             AND n.embedding IS NOT NULL
                           ORDER BY n.created_at ASC
                           LIMIT 1
                        ) AS note_embedding_text,
                        (
                          SELECT n.author_id
                            FROM public.note n
                           WHERE n.thread_id = t.id
                             AND n.archived_at IS NULL
                           ORDER BY n.created_at ASC
                           LIMIT 1
                        ) AS note_author_id,
                        t.created_by
                   FROM public.thread t
                   JOIN public.thread_priority tp
                     ON tp.thread_id = t.id AND tp.user_id = $1
                  WHERE (${likeClauses})
                    AND t.archived_at IS NULL`;
    const { rows } = await client.query<ThreadRow>(sql, [userId]);
    const byPrefix = new Map<string, ThreadRow>();
    for (const r of rows) {
      // Keep the earliest match per prefix (deterministic when a prefix
      // collides — vanishingly rare with 8 hex chars).
      const p = r.id.slice(0, 8);
      if (!byPrefix.has(p)) byPrefix.set(p, r);
    }

    for (const c of cases) {
      const m = prefixMatch(c.id);
      if (!m) {
        skipped++;
        continue;
      }
      const row = byPrefix.get(m[1]!);
      if (!row) {
        skipped++;
        continue;
      }

      const authorId = row.note_author_id ?? row.created_by;
      const authorRef = contactSlugById.get(authorId) ?? authorId;
      if (c.candidate.author !== authorRef) {
        c.candidate.author = authorRef;
        updatedAuthor++;
      }

      if (!c.candidate.embedding_ref) {
        const vec =
          parseHalfvec(row.embedding_text) ??
          parseHalfvec(row.note_embedding_text);
        if (vec) {
          const ref = `emb-${hashShort(row.id, 10)}`;
          if (!embRefs.has(ref)) {
            (world.embeddings ??= []).push({ ref, vector: vec });
            embRefs.add(ref);
          }
          c.candidate.embedding_ref = ref;
          updatedEmbedding++;
        }
      }
    }
  } finally {
    await client.end();
  }

  await writeFile(worldPath, stringifyYaml(world), "utf-8");
  await writeFile(casesPath, stringifyYaml(casesDoc), "utf-8");
  console.log(
    `Backfilled ${updatedAuthor} authors and ${updatedEmbedding} embeddings on ${opts.corpus}/cases.yaml (skipped ${skipped} cases).`
  );
}

function parseHalfvec(literal: string | null): number[] | null {
  if (!literal) return null;
  const inner = literal.trim().replace(/^\[/, "").replace(/\]$/, "");
  const parts = inner.split(",").map((s) => Number(s.trim()));
  return parts.length === 384 ? parts : null;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
