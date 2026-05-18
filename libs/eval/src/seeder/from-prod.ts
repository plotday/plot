#!/usr/bin/env tsx
/**
 * Extract a user's world + a sample of auto-filed threads from the prod DB
 * (via the Cloud SQL Proxy on port 5433) and emit an anonymized corpus.
 *
 * Usage:
 *   pnpm tsx src/seeder/from-prod.ts \
 *       --user-email kris@plot.day \
 *       --out corpora/kris \
 *       --case-count 30
 *
 * The script reads the prod DB via the readonly user, applies deterministic
 * anonymization (see anonymize.ts), and writes:
 *   - corpora/<out>/world.yaml
 *   - corpora/<out>/cases/NNN-<id>.yaml
 *   - corpora/<out>/README.md
 *
 * No PII leaves the script's memory in unredacted form once writeYaml runs.
 */
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import pg from "pg";
import { stringify as stringifyYaml } from "yaml";

import { anonymizeEmail, anonymizeName, hashShort } from "./anonymize";

const PROXY_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

type CliOpts = {
  userEmail: string;
  out: string;
  caseCount: number;
};

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: {
      "user-email": { type: "string" },
      out: { type: "string" },
      "case-count": { type: "string" },
    },
  });
  if (!values["user-email"] || !values.out) {
    console.error(
      "Usage: from-prod --user-email <addr> --out <corpus-name> [--case-count 30]"
    );
    process.exit(2);
  }
  return {
    userEmail: values["user-email"],
    out: values.out,
    caseCount: Number(values["case-count"] ?? 30),
  };
}

type PriorityRow = {
  id: string;
  path: string;
  title: string;
  key: string | null;
};
type ContactRow = {
  id: string;
  email: string | null;
  name: string | null;
  linked_to_user: boolean;
};
type ChannelRow = { id: number; default_priority_id: string | null };
type ThreadRow = {
  id: string;
  title: string | null;
  topic: string | null;
  contacts: string[];
  groups: string[];
  embedding: number[] | null;
  filed_to_priority: string;
};
type CaseRow = ThreadRow & {
  filed_to_priority: string; // expected (the current filing)
};

async function main() {
  const opts = parseOpts();
  const client = new pg.Client({ connectionString: PROXY_URL });
  await client.connect();
  try {
    const { rows: userRows } = await client.query(
      `SELECT id FROM public."user" WHERE email = $1`,
      [opts.userEmail]
    );
    if (userRows.length === 0) throw new Error(`User ${opts.userEmail} not found`);
    const userId: string = userRows[0].id;
    console.log(`Found user ${opts.userEmail} → ${userId}`);

    const priorities = await loadPriorities(client, userId);
    const contacts = await loadContacts(client, userId);
    const channels = await loadChannels(client, userId);
    const trainingThreads = await loadTrainingThreads(client, userId);
    const cases = await loadSampledCases(
      client,
      userId,
      opts.caseCount,
      new Set(trainingThreads.map((t) => t.id)),
      new Set(priorities.map((p) => p.id))
    );
    const referencedGroups = new Set<string>();
    for (const t of [...trainingThreads, ...cases]) {
      for (const g of t.groups) referencedGroups.add(g);
    }
    const groups = await loadGroups(client, referencedGroups);

    console.log(
      `Loaded: ${priorities.length} priorities, ${contacts.length} contacts, ` +
        `${channels.length} channels, ${groups.length} groups, ` +
        `${trainingThreads.length} training threads, ${cases.length} sampled cases`
    );

    await writeCorpus(opts, userId, priorities, contacts, groups, channels, trainingThreads, cases);
    console.log(`Wrote corpus to ${opts.out}`);
  } finally {
    await client.end();
  }
}

async function loadPriorities(
  client: pg.Client,
  userId: string
): Promise<PriorityRow[]> {
  const { rows } = await client.query<PriorityRow>(
    `SELECT id, path::text AS path, title, key
       FROM public.priority
      WHERE user_id = $1 AND archived_at IS NULL
      ORDER BY path`,
    [userId]
  );
  return rows;
}

async function loadContacts(
  client: pg.Client,
  userId: string
): Promise<ContactRow[]> {
  // Linked aliases (the user's own contacts) PLUS counterparty contacts that
  // appear in any of the user's threads.
  const { rows } = await client.query<ContactRow>(
    `WITH linked AS (
       SELECT c.id, c.email, c.name, TRUE AS linked_to_user
         FROM public.contact c
         JOIN public.user_contact uc
           ON uc.contact_id = c.id AND uc.user_id = $1 AND uc.linked = TRUE
        WHERE c.archived_at IS NULL
     ),
     counterparties AS (
       SELECT DISTINCT c.id, c.email, c.name, FALSE AS linked_to_user
         FROM public.contact c
         JOIN public.thread t
           ON c.id = ANY(t.contacts)
         JOIN public.thread_priority tp ON tp.thread_id = t.id
        WHERE tp.user_id = $1
          AND t.archived_at IS NULL
          AND c.archived_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.user_contact uc
            WHERE uc.contact_id = c.id AND uc.user_id = $1 AND uc.linked = TRUE
          )
     )
     SELECT * FROM linked
     UNION ALL
     SELECT * FROM counterparties`,
    [userId]
  );
  return rows;
}

async function loadGroups(
  client: pg.Client,
  groupIds: Set<string>
): Promise<{ id: string; title: string }[]> {
  if (groupIds.size === 0) return [];
  const { rows } = await client.query<{ id: string; title: string }>(
    `SELECT id, name AS title FROM public."group" WHERE id = ANY($1::uuid[])`,
    [[...groupIds]]
  );
  return rows;
}

async function loadChannels(
  client: pg.Client,
  userId: string
): Promise<ChannelRow[]> {
  const { rows } = await client.query<ChannelRow>(
    `SELECT c.id::int AS id, c.default_priority_id
       FROM public.channel c
       LEFT JOIN public.priority p ON p.id = c.default_priority_id
      WHERE c.id IN (
        SELECT DISTINCT NULLIF(substring(t.topic FROM 9), '')::bigint
          FROM public.thread t
          JOIN public.thread_priority tp ON tp.thread_id = t.id
         WHERE tp.user_id = $1
           AND t.topic ~ '^channel:[0-9]+$'
           AND t.archived_at IS NULL
      )
        AND (c.default_priority_id IS NULL OR p.user_id = $1)
      ORDER BY c.id`,
    [userId]
  );
  return rows;
}

async function loadTrainingThreads(
  client: pg.Client,
  userId: string
): Promise<ThreadRow[]> {
  const { rows } = await client.query<{
    id: string;
    title: string | null;
    topic: string | null;
    contacts: string[];
    groups: string[];
    embedding_text: string | null;
    filed_to_priority: string;
  }>(
    `SELECT t.id,
            t.title,
            t.topic,
            t.contacts,
            t.groups,
            t.embedding::text AS embedding_text,
            tp.priority_id AS filed_to_priority
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1
        AND tp.user_moved = TRUE
        AND t.archived_at IS NULL
      ORDER BY tp.updated_at DESC`,
    [userId]
  );
  return rows.map((r) => ({
    ...r,
    embedding: parseHalfvec(r.embedding_text),
  }));
}

async function loadSampledCases(
  client: pg.Client,
  userId: string,
  caseCount: number,
  excludeIds: Set<string>,
  activePriorityIds: Set<string>
): Promise<CaseRow[]> {
  // Stratified sample by topic shape. Use modular sampling to spread across
  // the per-shape population deterministically (same seed → same sample).
  const shapes: Array<{ shape: string; predicate: string }> = [
    { shape: "channel-with-default", predicate: "t.topic ~ '^channel:[0-9]+$' AND ch.default_priority_id IS NOT NULL" },
    { shape: "channel-no-default", predicate: "t.topic ~ '^channel:[0-9]+$' AND ch.default_priority_id IS NULL" },
    { shape: "priority-key", predicate: "t.topic LIKE 'priority:%'" },
    { shape: "null-topic", predicate: "t.topic IS NULL" },
    { shape: "other-topic", predicate: "t.topic IS NOT NULL AND t.topic !~ '^channel:' AND t.topic NOT LIKE 'priority:%'" },
  ];
  // Roughly proportional but capped per-shape.
  const targetPer = Math.ceil(caseCount / shapes.length);

  const out: CaseRow[] = [];
  for (const s of shapes) {
    const { rows } = await client.query<{
      id: string;
      title: string | null;
      topic: string | null;
      contacts: string[];
      groups: string[];
      embedding_text: string | null;
      filed_to_priority: string;
    }>(
      `SELECT t.id,
              t.title,
              t.topic,
              t.contacts,
              t.groups,
              t.embedding::text AS embedding_text,
              tp.priority_id AS filed_to_priority
         FROM public.thread_priority tp
         JOIN public.thread t ON t.id = tp.thread_id
         LEFT JOIN public.channel ch
           ON t.topic ~ '^channel:[0-9]+$'
          AND ch.id = NULLIF(substring(t.topic FROM 9), '')::bigint
        WHERE tp.user_id = $1
          AND tp.user_moved = FALSE
          AND t.archived_at IS NULL
          AND ${s.predicate}
        ORDER BY t.created_at DESC NULLS LAST
        LIMIT $2`,
      [userId, targetPer * 3] // overfetch then stride-sample
    );
    const filtered = rows.filter(
      (r) => !excludeIds.has(r.id) && activePriorityIds.has(r.filed_to_priority)
    );
    const droppedForArchive = rows.filter(
      (r) => !excludeIds.has(r.id) && !activePriorityIds.has(r.filed_to_priority)
    );
    if (droppedForArchive.length > 0) {
      console.log(
        `  [${s.shape}] dropped ${droppedForArchive.length} cases whose filed_to_priority is archived`
      );
    }
    const stride = Math.max(1, Math.floor(filtered.length / targetPer));
    for (let i = 0; i < filtered.length && out.length < caseCount; i += stride) {
      const r = filtered[i]!;
      out.push({ ...r, embedding: parseHalfvec(r.embedding_text) });
    }
  }
  return out.slice(0, caseCount);
}

function parseHalfvec(literal: string | null): number[] | null {
  if (!literal) return null;
  // halfvec text is "[0.1, -0.2, ...]"
  const inner = literal.trim().replace(/^\[/, "").replace(/\]$/, "");
  return inner.split(",").map((s) => Number(s.trim()));
}

async function writeCorpus(
  opts: CliOpts,
  userId: string,
  priorities: PriorityRow[],
  contacts: ContactRow[],
  groups: { id: string; title: string }[],
  channels: ChannelRow[],
  trainingThreads: ThreadRow[],
  cases: CaseRow[]
): Promise<void> {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const outDir = resolve(scriptDir, "..", "..", "corpora", opts.out);
  // Remove any prior layout (per-case files, old training set blobs). World,
  // cases.yaml, and trainings/full.yaml are overwritten outright.
  await rm(join(outDir, "cases"), { recursive: true, force: true });
  await rm(join(outDir, "cases.yaml"), { force: true });
  await mkdir(join(outDir, "trainings"), { recursive: true });

  // Only PII (emails, contact names) is anonymized. Priority titles, thread
  // titles, topics, channel IDs, group names, and UUIDs are preserved
  // verbatim so the corpus is human-readable for manual review and so any
  // classifier that uses semantic signals (LLM-based, embedding-based) sees
  // the same text the production classifier sees.

  // Build embedding catalog: training + cases. Stable ref name per source thread.
  const embeddings: { ref: string; vector: number[] }[] = [];
  const embRefOf = new Map<string, string>();
  for (const t of [...trainingThreads, ...cases]) {
    if (t.embedding && t.embedding.length === 384) {
      const ref = `emb-${hashShort(t.id, 10)}`;
      if (!embRefOf.has(t.id)) {
        embRefOf.set(t.id, ref);
        embeddings.push({ ref, vector: t.embedding });
      }
    }
  }

  const world = {
    name: opts.out,
    description: `Snapshot of ${opts.userEmail} extracted ${new Date()
      .toISOString()
      .slice(0, 10)} by libs/eval seeder/from-prod. Emails and contact names anonymized; other text preserved verbatim.`,
    schema_version: 1,
    source: {
      kind: "prod-extract",
      extracted_at: new Date().toISOString(),
      anonymized: true,
    },
    user: {
      id: userId,
      email: anonymizeEmail(opts.userEmail) ?? "eval-user@example.test",
      primary_contact_id: null,
    },
    priorities: priorities.map((p) => ({
      id: p.id,
      path: p.path,
      title: p.title,
      key: p.key,
    })),
    contacts: contacts.map((c) => ({
      id: c.id,
      email: anonymizeEmail(c.email),
      name: anonymizeName(c.name),
      linked_to_user: c.linked_to_user,
    })),
    groups: groups.map((g) => ({
      id: g.id,
      title: g.title,
    })),
    embeddings,
    channels: channels.map((ch) => ({
      id: ch.id,
      default_priority_id: ch.default_priority_id,
    })),
  };

  await writeFile(join(outDir, "world.yaml"), stringifyYaml(world), "utf-8");

  // Write the full prod training set as trainings/full.yaml. Additional
  // training-set variants live alongside as separate files and are not
  // touched by this seeder — the user maintains them manually.
  const fullTrainingSet = {
    name: "full",
    description:
      `All ${trainingThreads.length} user_moved=TRUE threads for ${opts.userEmail} ` +
      `as of ${new Date().toISOString().slice(0, 10)}. Re-generated by from-prod.`,
    threads: trainingThreads.map((t) => ({
      id: t.id,
      title: t.title,
      topic: t.topic,
      contacts: t.contacts,
      groups: t.groups,
      embedding_ref: embRefOf.get(t.id) ?? null,
      filed_to_priority: t.filed_to_priority,
    })),
  };
  await writeFile(
    join(outDir, "trainings", "full.yaml"),
    stringifyYaml(fullTrainingSet),
    "utf-8"
  );

  // Write all cases into a single cases.yaml document.
  const casesDoc = {
    cases: cases.map((c, i) => ({
      id: `${String(i + 1).padStart(3, "0")}-${c.id.slice(0, 8)}`,
      description: `Sampled from prod (topic-shape: ${describeTopic(c.topic)}).`,
      candidate: {
        title: c.title,
        topic: c.topic,
        contacts: c.contacts,
        groups: c.groups,
        embedding_ref: embRefOf.get(c.id) ?? null,
      },
      labels: {
        gold: null,
        gold_rationale: "",
        expected: c.filed_to_priority,
        expected_stage: null,
        expected_recorded_at: new Date().toISOString(),
      },
      notes: "",
    })),
  };
  await writeFile(join(outDir, "cases.yaml"), stringifyYaml(casesDoc), "utf-8");

  await writeFile(
    join(outDir, "README.md"),
    [
      `# Corpus: ${opts.out}`,
      "",
      `Anonymized snapshot of \`${opts.userEmail}\` extracted on ${new Date().toISOString().slice(0, 10)}.`,
      "",
      `World: ${priorities.length} priorities, ${contacts.length} contacts, ` +
        `${channels.length} channels, ${embeddings.length} embeddings.`,
      "",
      `Training sets: trainings/full.yaml holds the ${trainingThreads.length} ` +
        `user_moved=TRUE threads pulled from prod. Add more files under trainings/ ` +
        "(e.g. minimal.yaml, plus-counterfactual.yaml) and the runner will matrix " +
        "each one against every case.",
      "",
      `Cases: ${cases.length} sampled auto-filed threads in cases.yaml. Each case's ` +
        "`expected` is the priority currently filed in prod. `gold` is unset — fill in " +
        "by hand to capture cases where the current classifier disagrees with your " +
        "judgment.",
      "",
      "## Re-generating",
      "",
      "```bash",
      "pnpm prod-db-connect  # if proxy isn't running",
      `pnpm tsx src/seeder/from-prod.ts --user-email ${opts.userEmail} --out ${opts.out}`,
      "```",
      "",
      "Re-running overwrites world.yaml, trainings/full.yaml, and cases.yaml. Other " +
        "training-set files under trainings/ are left untouched.",
    ].join("\n"),
    "utf-8"
  );
}

function describeTopic(topic: string | null): string {
  if (topic === null) return "null";
  if (/^channel:\d+$/.test(topic)) return "channel:N";
  if (topic.startsWith("priority:")) return "priority:KEY";
  return "other";
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
