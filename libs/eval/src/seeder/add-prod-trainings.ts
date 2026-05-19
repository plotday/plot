#!/usr/bin/env tsx
/**
 * Append a set of curated prod threads to an existing corpus's training set.
 *
 * Unlike `from-prod.ts` (which regenerates `trainings/full.yaml` from every
 * `user_moved = TRUE` thread), this script appends specific thread UUIDs to
 * a named training set. Used to backfill training data for priorities that
 * have no `user_moved` examples in production but do have at least one filed
 * thread we can use as an anchor.
 *
 * It:
 *   - Reads existing `world.yaml` and `trainings/<set>.yaml`
 *   - For each thread UUID passed, queries prod, derives author from the
 *     earliest note's author_id (falling back to thread.created_by), and
 *     backfills embedding from the earliest note when thread.embedding is null
 *   - Appends those threads to the training set
 *   - Adds any newly-referenced embeddings to `world.yaml`
 *
 * Usage:
 *   pnpm tsx src/seeder/add-prod-trainings.ts --corpus kris --set full \
 *     --threads 019e0e03-6ce9-...,019e0797-5397-...
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import pg from "pg";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";

import { anonymizeEmail, anonymizeName, hashShort } from "./anonymize";
import { contactSlugFromEmail, uniqueSlugifier } from "./slugs";

const PROD_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

type CliOpts = { corpus: string; set: string; threadIds: string[] };

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      set: { type: "string" },
      threads: { type: "string" },
    },
  });
  if (!values.corpus || !values.threads) {
    console.error(
      "Usage: add-prod-trainings --corpus <name> [--set full] --threads <uuid1,uuid2,...>"
    );
    process.exit(2);
  }
  return {
    corpus: values.corpus,
    set: values.set ?? "full",
    threadIds: values.threads.split(",").map((s) => s.trim()).filter(Boolean),
  };
}

type ThreadRow = {
  id: string;
  title: string | null;
  topic: string | null;
  contacts: string[];
  groups: string[];
  embedding_text: string | null;
  note_embedding_text: string | null;
  note_author_id: string | null;
  created_by: string;
  filed_to_priority: string;
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

  const prioritySlugById = new Map<string, string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    world.priorities.map((p: any) => [p.id, p.slug])
  );
  const contactSlugById = new Map<string, string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.contacts ?? []).map((c: any) => [c.id, c.slug])
  );
  const groupSlugById = new Map<string, string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.groups ?? []).map((g: any) => [g.id, g.slug])
  );

  const embRefs = new Set<string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.embeddings ?? []).map((e: any) => e.ref as string)
  );

  const existingThreadIds = new Set<string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (trainingDoc.threads ?? []).map((t: any) => t.id as string)
  );

  // Slugifiers seeded with existing slugs so newly-fetched contacts/groups
  // don't collide.
  const contactSlugify = uniqueSlugifier(
    new Set(contactSlugById.values())
  );
  const groupSlugify = uniqueSlugifier(new Set(groupSlugById.values()));

  const client = new pg.Client({ connectionString: PROD_URL });
  await client.connect();
  let added = 0;
  try {
    for (const threadId of opts.threadIds) {
      if (existingThreadIds.has(threadId)) {
        console.log(`  = ${threadId} already in training set; skipping`);
        continue;
      }
      const { rows } = await client.query<ThreadRow>(
        `SELECT t.id, t.title, t.topic, t.contacts, t.groups,
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
                t.created_by,
                tp.priority_id AS filed_to_priority
           FROM public.thread t
           JOIN public.thread_priority tp
             ON tp.thread_id = t.id AND tp.user_id = $1
          WHERE t.id = $2`,
        [userId, threadId]
      );
      if (rows.length === 0) {
        console.warn(`  ! thread ${threadId} not found for user`);
        continue;
      }
      const row = rows[0]!;
      const expectedSlug = prioritySlugById.get(row.filed_to_priority);
      if (!expectedSlug) {
        console.warn(
          `  ! thread ${threadId} filed in archived/unknown priority ${row.filed_to_priority}; skipping`
        );
        continue;
      }

      const contactSlugs: string[] = [];
      for (const id of row.contacts) {
        let slug = contactSlugById.get(id);
        if (!slug) {
          slug = await fetchAndAppendContact(
            client,
            id,
            userId,
            world,
            contactSlugById,
            contactSlugify
          );
        }
        contactSlugs.push(slug);
      }
      const groupSlugs: string[] = [];
      for (const id of row.groups) {
        let slug = groupSlugById.get(id);
        if (!slug) {
          slug = await fetchAndAppendGroup(
            client,
            id,
            world,
            groupSlugById,
            groupSlugify
          );
        }
        groupSlugs.push(slug);
      }

      let embeddingRef: string | null = null;
      const vec =
        parseHalfvec(row.embedding_text) ??
        parseHalfvec(row.note_embedding_text);
      if (vec) {
        embeddingRef = `emb-${hashShort(row.id, 10)}`;
        if (!embRefs.has(embeddingRef)) {
          (world.embeddings ??= []).push({ ref: embeddingRef, vector: vec });
          embRefs.add(embeddingRef);
        }
      }

      const authorId = row.note_author_id ?? row.created_by;
      const authorRef = contactSlugById.get(authorId) ?? authorId;

      (trainingDoc.threads ??= []).push({
        id: row.id,
        title: row.title,
        topic: row.topic,
        contacts: contactSlugs,
        groups: groupSlugs,
        embedding_ref: embeddingRef,
        filed_to_priority: expectedSlug,
        author: authorRef,
      });
      existingThreadIds.add(row.id);
      added++;
      console.log(
        `  + ${row.id} → ${expectedSlug}  ${row.title?.slice(0, 60) ?? "(no title)"}`
      );
    }
  } finally {
    await client.end();
  }

  await writeFile(worldPath, stringifyYaml(world), "utf-8");
  await writeFile(setPath, stringifyYaml(trainingDoc), "utf-8");
  console.log(
    `Added ${added}/${opts.threadIds.length} threads to ${opts.corpus}/trainings/${opts.set}.yaml`
  );
}

function parseHalfvec(literal: string | null): number[] | null {
  if (!literal) return null;
  const inner = literal.trim().replace(/^\[/, "").replace(/\]$/, "");
  const parts = inner.split(",").map((s) => Number(s.trim()));
  return parts.length === 384 ? parts : null;
}

// Fetch a contact from prod and append it to world.contacts. Anonymizes email
// + name to match `from-prod.ts` conventions. linked_to_user is computed via
// user_contact join so the sandbox replicates linked-alias visibility.
async function fetchAndAppendContact(
  client: pg.Client,
  contactId: string,
  userId: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  world: any,
  contactSlugById: Map<string, string>,
  slugify: (input: string, fallback?: string) => string
): Promise<string> {
  const { rows } = await client.query<{
    id: string;
    email: string | null;
    name: string | null;
    linked: boolean;
  }>(
    `SELECT c.id,
            c.email,
            c.name,
            EXISTS (
              SELECT 1 FROM public.user_contact uc
               WHERE uc.contact_id = c.id
                 AND uc.user_id = $2
                 AND uc.linked = TRUE
            ) AS linked
       FROM public.contact c
      WHERE c.id = $1`,
    [contactId, userId]
  );
  if (rows.length === 0) {
    throw new Error(`Contact ${contactId} not found in prod`);
  }
  const c = rows[0]!;
  const anonEmail = anonymizeEmail(c.email);
  const base = contactSlugFromEmail(anonEmail, c.id);
  const slug = slugify(base, `c-${c.id.replace(/-/g, "").slice(0, 8)}`);
  (world.contacts ??= []).push({
    slug,
    id: c.id,
    email: anonEmail,
    name: anonymizeName(c.name),
    linked_to_user: c.linked,
  });
  contactSlugById.set(c.id, slug);
  return slug;
}

async function fetchAndAppendGroup(
  client: pg.Client,
  groupId: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  world: any,
  groupSlugById: Map<string, string>,
  slugify: (input: string, fallback?: string) => string
): Promise<string> {
  const { rows } = await client.query<{ id: string; title: string }>(
    `SELECT id, name AS title FROM public."group" WHERE id = $1`,
    [groupId]
  );
  if (rows.length === 0) {
    throw new Error(`Group ${groupId} not found in prod`);
  }
  const g = rows[0]!;
  const slug = slugify(g.title, `g-${g.id.replace(/-/g, "").slice(0, 8)}`);
  (world.groups ??= []).push({ slug, id: g.id, title: g.title });
  groupSlugById.set(g.id, slug);
  return slug;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
