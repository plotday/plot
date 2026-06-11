#!/usr/bin/env tsx
/**
 * Mine `classification_decision` history into labeled cases (spec C3).
 *
 * For the corpus user, each `user_move` row paired with the LATEST earlier
 * non-user_move decision for the same (user, thread) where the moved-to
 * priority differs from the auto decision is a labeled misclassification:
 * gold = the move target (`gold_source: human`, tag `decision-log`),
 * expected = the auto decision's choice, `as_of` = the auto decision's
 * `created_at`. Mined threads are hydrated + anonymized and appended to an
 * existing v2 corpus exactly like add-prod-cases, but with labels prefilled.
 *
 * Asymmetry note (recorded in each low-confidence case's `notes`): the TS
 * cascade's no-match bucket logs stage `none` with a NULL priority, while the
 * SQL trigger paths log stage `sql:applied` with the resolved root — both
 * represent the classifier's low-confidence bucket.
 *
 * An empty or missing table (prod until the decision log deploys) prints an
 * informative message and exits 0.
 *
 * Usage:
 *   pnpm exec tsx src/seeder/from-decision-log.ts --corpus kris [--db-url <url>]
 */
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

import pg from "pg";
import { parse as parseYaml } from "yaml";

import { appendProdThreads, type CaseOverride } from "./append";
import type { PgClient } from "./extract";

const DEFAULT_DB_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

// ===========================================================================
// Core mining (testable without prod)
// ===========================================================================

export type MinedCase = {
  threadId: string;
  /** The auto decision's choice; NULL for the TS no-match bucket (stage 'none'). */
  autoPriorityId: string | null;
  autoStage: string;
  autoClassifier: string;
  /** The auto decision's created_at (ISO) — the case's as_of. */
  decidedAt: string;
  /** The user_move target — the gold label. */
  movedTo: string;
};

/**
 * Mines labeled misclassifications for one user. Per thread, only the LATEST
 * user_move counts (the final destination is the ground truth); it is paired
 * with the latest earlier non-user_move decision and qualifies when the two
 * priorities differ (`IS DISTINCT FROM` — a NULL auto priority vs a real move
 * target qualifies). A missing table (SQLSTATE 42P01) is reported gracefully.
 */
export async function mineDecisionLog(
  client: PgClient,
  userId: string
): Promise<{ tableMissing: boolean; mined: MinedCase[] }> {
  try {
    const { rows } = await client.query<{
      thread_id: string;
      auto_priority: string | null;
      stage: string;
      classifier: string;
      decided_at: Date;
      moved_to: string;
    }>(
      `WITH latest_move AS (
         SELECT DISTINCT ON (thread_id) *
           FROM public.classification_decision
          WHERE user_id = $1 AND stage = 'user_move'
          ORDER BY thread_id, created_at DESC, id DESC
       )
       SELECT m.thread_id,
              a.priority_id AS auto_priority,
              a.stage,
              a.classifier,
              a.created_at AS decided_at,
              m.priority_id AS moved_to
         FROM latest_move m
         JOIN LATERAL (
           SELECT * FROM public.classification_decision a
            WHERE a.thread_id = m.thread_id AND a.user_id = m.user_id
              AND a.stage <> 'user_move' AND a.created_at < m.created_at
            ORDER BY a.created_at DESC, a.id DESC LIMIT 1
         ) a ON TRUE
        WHERE m.priority_id IS DISTINCT FROM a.priority_id
        ORDER BY m.created_at ASC, m.thread_id`,
      [userId]
    );
    return {
      tableMissing: false,
      mined: rows.map((r) => ({
        threadId: r.thread_id,
        autoPriorityId: r.auto_priority,
        autoStage: r.stage,
        autoClassifier: r.classifier,
        decidedAt: new Date(r.decided_at).toISOString(),
        movedTo: r.moved_to,
      })),
    };
  } catch (err) {
    if ((err as { code?: string }).code === "42P01") {
      return { tableMissing: true, mined: [] };
    }
    throw err;
  }
}

// ===========================================================================
// Case-label building (pure; exported for tests)
// ===========================================================================

/** Stages that form the classifier's low-confidence bucket (see note below). */
const LOW_CONFIDENCE_STAGES = new Set(["none", "sql:applied"]);

const ASYMMETRY_NOTE =
  "Asymmetry: the TS cascade's no-match bucket logs stage 'none' with a " +
  "NULL priority, while the SQL trigger paths log stage 'sql:applied' with " +
  "the resolved root — both represent the classifier's low-confidence bucket.";

/**
 * Builds the appendProdThreads case override for one mined decision. Slug
 * resolution (priority id → corpus slug) is the caller's job; `expectedSlug`
 * is null both for the TS no-match bucket (NULL auto priority) and for auto
 * priorities missing from the corpus world.
 */
export function minedCaseOverride(args: {
  mined: MinedCase;
  goldSlug: string;
  expectedSlug: string | null;
  recordedAtIso: string;
}): CaseOverride {
  const { mined, goldSlug, expectedSlug, recordedAtIso } = args;
  return {
    tags: ["decision-log"],
    description: `Mined from classification_decision: user moved off the ${mined.autoStage} decision (${mined.autoClassifier}).`,
    asOf: mined.decidedAt,
    notes: LOW_CONFIDENCE_STAGES.has(mined.autoStage) ? ASYMMETRY_NOTE : "",
    labels: {
      gold: goldSlug,
      gold_rationale: `mined from classification_decision: user moved off ${mined.autoStage} decision`,
      gold_source: "human",
      expected: expectedSlug,
      expected_stage: mined.autoStage,
      expected_recorded_at: recordedAtIso,
    },
  };
}

// ===========================================================================
// CLI
// ===========================================================================

// Loosely-typed YAML documents (same stance as append.ts).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type YamlDoc = any;

async function main() {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      "db-url": { type: "string" },
    },
  });
  if (!values.corpus) {
    console.error("Usage: from-decision-log --corpus <name> [--db-url <url>]");
    process.exit(2);
  }
  const corpus = values.corpus;
  const dbUrl = values["db-url"] ?? DEFAULT_DB_URL;

  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = resolve(scriptDir, "..", "..", "corpora", corpus);

  let worldText: string;
  try {
    worldText = await readFile(join(corpusDir, "world.yaml"), "utf-8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      console.error(`Corpus '${corpus}' not found at ${corpusDir} (no world.yaml).`);
      process.exit(2);
    }
    throw err;
  }
  const world: YamlDoc = parseYaml(worldText);
  if (world?.schema_version !== 2) {
    throw new Error(
      `Corpus '${corpus}' is schema v${world?.schema_version ?? 1}; the decision-log ` +
        `miner requires v2. Re-extract it first: pnpm exec tsx src/seeder/from-prod.ts --out ${corpus} ...`
    );
  }
  const userId: string = world.user.id;
  const prioritySlugById = new Map<string, string>(
    (world.priorities ?? []).map((p: YamlDoc) => [p.id, p.slug])
  );

  const client = new pg.Client({ connectionString: dbUrl });
  await client.connect();
  let result: Awaited<ReturnType<typeof mineDecisionLog>>;
  try {
    result = await mineDecisionLog(client, userId);
  } finally {
    await client.end();
  }
  if (result.tableMissing) {
    console.log(
      "classification_decision is absent — prod hasn't deployed the decision log yet; nothing to mine"
    );
    return;
  }
  if (result.mined.length === 0) {
    console.log(
      "no user corrections disagree with logged auto decisions; nothing to mine"
    );
    return;
  }
  console.log(`Mined ${result.mined.length} corrected decision(s) for ${corpus}`);

  // Threads already present as cases are skipped (source_thread_id dedupe).
  const casesDoc: YamlDoc = parseYaml(
    await readFile(join(corpusDir, "cases.yaml"), "utf-8")
  );
  const existingSourceIds = new Set<string>(
    ((casesDoc?.cases ?? []) as YamlDoc[])
      .map((c) => c.source_thread_id as string | null | undefined)
      .filter((id): id is string => typeof id === "string" && id.length > 0)
  );

  const recordedAtIso = new Date().toISOString();
  const overrides = new Map<string, CaseOverride>();
  let alreadyPresent = 0;
  for (const m of result.mined) {
    if (existingSourceIds.has(m.threadId)) {
      alreadyPresent++;
      continue;
    }
    const goldSlug = prioritySlugById.get(m.movedTo);
    if (!goldSlug) {
      console.warn(
        `  ! thread ${m.threadId}: moved-to priority ${m.movedTo} not in corpus world (archived/unknown); skipping`
      );
      continue;
    }
    const expectedSlug = m.autoPriorityId
      ? (prioritySlugById.get(m.autoPriorityId) ?? null)
      : null;
    if (m.autoPriorityId !== null && expectedSlug === null) {
      console.warn(
        `  ! thread ${m.threadId}: auto priority ${m.autoPriorityId} not in corpus world; expected label left null`
      );
    }
    overrides.set(
      m.threadId,
      minedCaseOverride({ mined: m, goldSlug, expectedSlug, recordedAtIso })
    );
  }

  if (alreadyPresent > 0) {
    console.log(
      `  = ${alreadyPresent} mined thread(s) already present as cases; skipped`
    );
  }
  if (overrides.size === 0) {
    console.log("Nothing new to append.");
    return;
  }

  await appendProdThreads({
    corpus,
    threadIds: [...overrides.keys()],
    mode: { kind: "cases" },
    dbUrl,
    // note-content vectors are own-data-only; kris keeps them by default.
    allowNoteContentEmbeddings: corpus === "kris",
    caseOverrides: overrides,
  });
}

// Only run the CLI when executed directly (tests import the exports above).
const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (invokedDirectly) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
