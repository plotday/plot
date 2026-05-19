#!/usr/bin/env tsx
/**
 * Backfill `author` and `embedding_ref` on every thread in a corpus's
 * training set by re-querying the prod DB.
 *
 * Unlike `from-prod.ts` (which regenerates world.yaml, cases.yaml, and
 * trainings/full.yaml from scratch), this script preserves all hand-curated
 * state (gold labels, expected_stage, notes, etc.). It only:
 *   - Reads existing world.yaml and trainings/<set>.yaml
 *   - For each thread already in the set, queries prod for author_id (the
 *     earliest note's author_id, falling back to thread.created_by) and an
 *     embedding (thread.embedding, falling back to the earliest note's
 *     embedding when null)
 *   - Updates the thread row in place with author + embedding_ref
 *   - Adds new embeddings to world.yaml.embeddings
 *
 * Usage:
 *   pnpm tsx src/seeder/backfill-trainings.ts --corpus kris --set full
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

type CliOpts = { corpus: string; set: string };

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      set: { type: "string" },
    },
  });
  if (!values.corpus) {
    console.error(
      "Usage: backfill-trainings --corpus <name> [--set full]"
    );
    process.exit(2);
  }
  return {
    corpus: values.corpus,
    set: values.set ?? "full",
  };
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
  const setPath = join(corpusDir, "trainings", `${opts.set}.yaml`);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const world = parseYaml(await readFile(worldPath, "utf-8")) as any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const trainingDoc = parseYaml(await readFile(setPath, "utf-8")) as any;

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
  const threads = (trainingDoc.threads ?? []) as any[];
  const ids = threads.map((t) => t.id as string);

  const client = new pg.Client({ connectionString: PROD_URL });
  await client.connect();
  let updatedAuthor = 0;
  let updatedEmbedding = 0;
  try {
    const { rows } = await client.query<ThreadRow>(
      `SELECT t.id,
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
        WHERE t.id = ANY($2::uuid[])`,
      [userId, ids]
    );
    const byId = new Map<string, ThreadRow>(rows.map((r) => [r.id, r]));

    for (const t of threads) {
      const row = byId.get(t.id);
      if (!row) {
        console.warn(`  ! thread ${t.id} not found for user; skipping`);
        continue;
      }
      // Backfill author from note.author_id, with thread.created_by as
      // fallback. Map to a contact slug when the author is one of the
      // user's known contacts.
      const authorId = row.note_author_id ?? row.created_by;
      const authorRef = contactSlugById.get(authorId) ?? authorId;
      if (t.author !== authorRef) {
        t.author = authorRef;
        updatedAuthor++;
      }
      // Backfill embedding when the training row has none. Prefer thread,
      // then earliest note. Leave untouched if both are null.
      if (!t.embedding_ref) {
        const vec =
          parseHalfvec(row.embedding_text) ??
          parseHalfvec(row.note_embedding_text);
        if (vec) {
          const ref = `emb-${hashShort(row.id, 10)}`;
          if (!embRefs.has(ref)) {
            (world.embeddings ??= []).push({ ref, vector: vec });
            embRefs.add(ref);
          }
          t.embedding_ref = ref;
          updatedEmbedding++;
        }
      }
    }
  } finally {
    await client.end();
  }

  await writeFile(worldPath, stringifyYaml(world), "utf-8");
  await writeFile(setPath, stringifyYaml(trainingDoc), "utf-8");
  console.log(
    `Backfilled ${updatedAuthor} authors and ${updatedEmbedding} embeddings on ${opts.corpus}/trainings/${opts.set}.yaml`
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
