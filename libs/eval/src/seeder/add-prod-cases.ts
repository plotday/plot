#!/usr/bin/env tsx
/**
 * Append a set of curated prod threads to an existing corpus as new cases.
 *
 * Unlike `from-prod.ts` (which rebuilds world.yaml + cases.yaml from scratch
 * via stratified random sampling), this script:
 *   - Reads existing world.yaml and cases.yaml
 *   - For each thread UUID passed, queries prod, anonymizes contact PII,
 *     and produces a new case entry
 *   - Appends those cases to cases.yaml — preserving existing case ids,
 *     gold labels, expected labels, and rationale text
 *   - Adds any newly-referenced embeddings to world.yaml's embeddings list
 *     (other world fields stay untouched)
 *
 * Usage:
 *   pnpm tsx src/seeder/add-prod-cases.ts --corpus kris \
 *     --threads 019e0e03-6ce9-...,019e0797-5397-...,...
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

type CliOpts = { corpus: string; threadIds: string[] };

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      threads: { type: "string" },
    },
  });
  if (!values.corpus || !values.threads) {
    console.error(
      "Usage: add-prod-cases --corpus <name> --threads <uuid1,uuid2,...>"
    );
    process.exit(2);
  }
  return {
    corpus: values.corpus,
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
  filed_to_priority: string;
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

  // Pull the user id from world.yaml so we query prod for that exact user.
  const userId: string = world.user.id;

  // Build slug lookups already in the world. We may add new contacts/groups
  // if the picks reference ones not previously sampled, but in practice the
  // initial seeder already pulled all counterparty contacts for the user.
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

  // Existing embedding refs so we don't double-add. Map source thread → ref.
  const embRefs = new Set<string>(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (world.embeddings ?? []).map((e: any) => e.ref as string)
  );

  // Existing case ids (so we don't collide) and the next sequential prefix.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const existingCaseIds = new Set<string>(casesDoc.cases.map((c: any) => c.id));
  let nextN =
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    casesDoc.cases.reduce((max: number, c: any) => {
      const m = (c.id as string).match(/^(\d+)-/);
      return m ? Math.max(max, Number(m[1])) : max;
    }, 0) + 1;

  const client = new pg.Client({ connectionString: PROD_URL });
  await client.connect();
  let added = 0;
  try {
    for (const threadId of opts.threadIds) {
      const { rows } = await client.query<ThreadRow>(
        `SELECT t.id, t.title, t.topic, t.contacts, t.groups,
                t.embedding::text AS embedding_text,
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

      // Resolve contact slugs (must already exist in world.yaml; the initial
      // seeder pulls every counterparty).
      const contactSlugs = row.contacts.map((id) => {
        const slug = contactSlugById.get(id);
        if (!slug) {
          // Backfill: extend world.contacts with a minimal record so the
          // case can reference it. Hit the prod DB for this contact's email.
          throw new Error(
            `Contact ${id} on thread ${threadId} not in world.yaml. ` +
              `Run the full seeder (from-prod.ts) first to refresh contacts.`
          );
        }
        return slug;
      });
      const groupSlugs = row.groups.map((id) => {
        const slug = groupSlugById.get(id);
        if (!slug) {
          throw new Error(
            `Group ${id} on thread ${threadId} not in world.yaml. ` +
              `Run the full seeder to refresh groups.`
          );
        }
        return slug;
      });

      // Embedding: parse the halfvec text and add to world.embeddings if any.
      let embeddingRef: string | null = null;
      const vec = parseHalfvec(row.embedding_text);
      if (vec) {
        embeddingRef = `emb-${hashShort(row.id, 10)}`;
        if (!embRefs.has(embeddingRef)) {
          (world.embeddings ??= []).push({ ref: embeddingRef, vector: vec });
          embRefs.add(embeddingRef);
        }
      }

      // Build the case id. Use the next sequential index plus the 8-char prefix.
      let id = `${String(nextN).padStart(3, "0")}-${row.id.slice(0, 8)}`;
      while (existingCaseIds.has(id)) {
        nextN++;
        id = `${String(nextN).padStart(3, "0")}-${row.id.slice(0, 8)}`;
      }
      existingCaseIds.add(id);
      nextN++;

      casesDoc.cases.push({
        id,
        description: `Curated from prod (manual pick, ${describeShape(row.topic)}).`,
        candidate: {
          title: row.title ?? "",
          topic: row.topic,
          contacts: contactSlugs,
          groups: groupSlugs,
          embedding_ref: embeddingRef,
        },
        labels: {
          gold: null,
          gold_rationale: "",
          expected: expectedSlug,
          expected_stage: null,
          expected_recorded_at: new Date().toISOString(),
        },
        notes: "",
      });
      added++;
      console.log(`  + ${id} → ${expectedSlug}  ${row.title?.slice(0, 60) ?? "(no title)"}`);
    }
  } finally {
    await client.end();
  }

  // PII reminder: emails and names. Even though we didn't expand into the
  // contact rows here, we may need to re-anonymize if we ever do.
  void anonymizeEmail;
  void anonymizeName;
  void contactSlugFromEmail;
  void uniqueSlugifier;

  await writeFile(worldPath, stringifyYaml(world), "utf-8");
  await writeFile(casesPath, stringifyYaml(casesDoc), "utf-8");
  console.log(`Added ${added}/${opts.threadIds.length} cases to ${opts.corpus}`);
}

function parseHalfvec(literal: string | null): number[] | null {
  if (!literal) return null;
  const inner = literal.trim().replace(/^\[/, "").replace(/\]$/, "");
  const parts = inner.split(",").map((s) => Number(s.trim()));
  return parts.length === 384 ? parts : null;
}

function describeShape(topic: string | null): string {
  if (topic === null) return "no-topic";
  if (/^channel:\d+$/.test(topic)) return "channel:N";
  if (topic.startsWith("priority:")) return "priority:KEY";
  return "other";
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
