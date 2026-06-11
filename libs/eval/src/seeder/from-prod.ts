#!/usr/bin/env tsx
/**
 * Extract a user's world + threads from the prod DB (via the Cloud SQL Proxy
 * on port 5433) and emit an anonymized corpus (schema v2).
 *
 * Usage:
 *   pnpm exec tsx src/seeder/from-prod.ts \
 *       --user-email kris@plot.day --out kris \
 *       --case-count 80 --holdout-recent-moves 10
 *
 *   pnpm exec tsx src/seeder/from-prod.ts --list-active-users
 *
 * Everything data-shaped goes through src/seeder/extract.ts (hydration) and
 * src/seeder/emit.ts (buildCorpusFiles — anonymization + enforced leak
 * check). main() is thin orchestration over those tested functions:
 *
 * - Training set: every user_moved=TRUE thread, MINUS the N most recent
 *   moves when --holdout-recent-moves is given. Holdout threads become gold
 *   cases tagged `holdout-move`.
 * - Refresh-preserving-labels: when <out>/cases.yaml exists, each existing
 *   case is re-hydrated by source_thread_id (falling back to the 8-hex
 *   prefix in the case id, with multi-match prefixes disambiguated by exact
 *   candidate-title equality); labels/tags/notes survive byte-exactly, the
 *   candidate is upgraded to v2. Unresolvable cases are kept verbatim and
 *   reported. New cases are sampled to top up to --case-count.
 * - Slug migration: contact slugs derive from the anonymized emails, so a
 *   refresh rewrites slugs in every emitted file AND in extra training files
 *   (e.g. kris's first-day.yaml) that this seeder does not regenerate.
 */
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

import pg from "pg";
import { parse as parseYaml } from "yaml";

import {
  hydrateThreadsByIds,
  listActiveUsers,
  loadConnections,
  loadContactsByIds,
  loadGroupsByIds,
  loadNegatives,
  loadTrainingThreads,
  loadWorldEntities,
  resolveThreadIdPrefix,
  resolveUserIdByEmail,
  sampleStratifiedCaseThreadIds,
  sampleTimelineCaseThreadIds,
  type ExtractedThread,
  type ExtractedWorld,
  type PgClient,
} from "./extract";
import {
  applySlugMigrationToYamlText,
  buildCorpusFiles,
  holdoutCaseEntries,
  mergeExistingCases,
  sampledCaseEntries,
  splitHoldout,
  type CaseResolution,
} from "./emit";

const DEFAULT_DB_URL =
  process.env.PROD_DB_URL ?? "postgres://readonly@127.0.0.1:5433/plot";

/** note-content embeddings embed private message bodies; kris-only. */
const NOTE_EMBEDDING_ALLOWED_EMAILS = new Set(["kris@plot.day"]);

type CliOpts = {
  userEmail: string | null;
  userId: string | null;
  out: string | null;
  caseCount: number;
  holdoutRecentMoves: number;
  timelineCases: number | null;
  dbUrl: string;
  listActive: boolean;
};

function usage(): never {
  console.error(
    [
      "Usage:",
      "  from-prod --user-email <addr> --out <corpus-name> [options]",
      "  from-prod --user-id <uuid> --out <corpus-name> [options]",
      "  from-prod --list-active-users [--db-url <url>]",
      "",
      "Options:",
      "  --case-count N            target number of non-holdout cases (default 80)",
      "  --holdout-recent-moves N  drop the N most recent user-moved threads from the",
      "                            training set and emit them as gold `holdout-move` cases",
      "  --timeline-cases N        top up with N cases spread evenly over thread.created_at",
      "                            instead of stratified topic-shape sampling",
      "  --db-url <url>            Postgres URL (default: $PROD_DB_URL or the readonly proxy)",
      "",
      "Notes:",
      "  - Refresh-preserving-labels: when <out>/cases.yaml exists, existing cases are",
      "    re-hydrated by source_thread_id (or 8-hex case-id prefix); gold/expected labels,",
      "    tags, and notes are preserved byte-for-byte.",
      "  - note-content embedding vectors are included only for kris@plot.day (own data).",
      "  - --list-active-users prints user ids and counts only — never emails.",
    ].join("\n")
  );
  process.exit(2);
}

function parseOpts(): CliOpts {
  const { values } = parseArgs({
    options: {
      "user-email": { type: "string" },
      "user-id": { type: "string" },
      out: { type: "string" },
      "case-count": { type: "string" },
      "holdout-recent-moves": { type: "string" },
      "timeline-cases": { type: "string" },
      "db-url": { type: "string" },
      "list-active-users": { type: "boolean" },
    },
  });
  const opts: CliOpts = {
    userEmail: values["user-email"] ?? null,
    userId: values["user-id"] ?? null,
    out: values.out ?? null,
    caseCount: Number(values["case-count"] ?? 80),
    holdoutRecentMoves: Number(values["holdout-recent-moves"] ?? 0),
    timelineCases:
      values["timeline-cases"] !== undefined
        ? Number(values["timeline-cases"])
        : null,
    dbUrl: values["db-url"] ?? DEFAULT_DB_URL,
    listActive: values["list-active-users"] ?? false,
  };
  if (!opts.listActive && !((opts.userEmail || opts.userId) && opts.out)) {
    usage();
  }
  return opts;
}

async function readOptional(path: string): Promise<string | undefined> {
  try {
    return await readFile(path, "utf-8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw err;
  }
}

/**
 * Resolves each existing case to a fresh prod hydration: by source_thread_id
 * when present, else by the 8-hex thread-id prefix embedded in the case id.
 * uuidv7 prefixes collide heavily (the 8 hex chars are mostly a timestamp:
 * one observed kris prefix matched 42 threads), so a multi-match prefix is
 * disambiguated by exact title equality with the existing case's candidate
 * title — titles are preserved verbatim by policy, so equality is sound.
 * Still-ambiguous or unmatched cases resolve to verbatim preservation.
 *
 * Exported for tests (tests/extract.test.ts).
 */
export async function resolveExistingCases(
  client: PgClient,
  userId: string,
  existingCases: Record<string, unknown>[]
): Promise<Map<string, CaseResolution>> {
  const resolution = new Map<string, CaseResolution>();
  const bySource: { caseId: string; threadId: string }[] = [];
  const byPrefix: { caseId: string; prefix: string; title: string | null }[] =
    [];

  for (const raw of existingCases) {
    const caseId = String(raw.id ?? "");
    const src =
      typeof raw.source_thread_id === "string" ? raw.source_thread_id : null;
    if (src) {
      bySource.push({ caseId, threadId: src });
      continue;
    }
    const m = /^\d+-([0-9a-f]{8})$/i.exec(caseId);
    if (m) {
      // Candidate title, used only to disambiguate multi-match prefixes. An
      // empty/missing title is no evidence, so it disables disambiguation.
      const cand = raw.candidate as Record<string, unknown> | undefined;
      const title =
        typeof cand?.title === "string" && cand.title !== ""
          ? cand.title
          : null;
      byPrefix.push({ caseId, prefix: m[1]!.toLowerCase(), title });
    } else {
      resolution.set(caseId, { status: "missing" });
    }
  }

  const sourceThreads = await hydrateThreadsByIds(
    client,
    userId,
    bySource.map((s) => s.threadId)
  );
  const threadById = new Map(sourceThreads.map((t) => [t.id, t]));
  for (const { caseId, threadId } of bySource) {
    const thread = threadById.get(threadId);
    resolution.set(
      caseId,
      thread ? { status: "hydrated", thread } : { status: "missing" }
    );
  }

  for (const { caseId, prefix, title } of byPrefix) {
    const matches = await resolveThreadIdPrefix(client, userId, prefix);
    if (matches.length === 0) {
      resolution.set(caseId, { status: "missing" });
      continue;
    }
    if (matches.length === 1) {
      const [thread] = await hydrateThreadsByIds(client, userId, matches);
      resolution.set(
        caseId,
        thread ? { status: "hydrated", thread } : { status: "missing" }
      );
      continue;
    }
    // Multi-match prefix: exactly one thread whose verbatim title equals the
    // case's candidate title wins; zero or several keep the case verbatim.
    if (title !== null) {
      const threads = await hydrateThreadsByIds(client, userId, matches);
      const titleMatches = threads.filter((t) => t.title === title);
      if (titleMatches.length === 1) {
        resolution.set(caseId, {
          status: "hydrated",
          thread: titleMatches[0]!,
        });
        continue;
      }
    }
    resolution.set(caseId, { status: "ambiguous", matches: matches.length });
  }
  return resolution;
}

/**
 * Ensures every contact/group/connection referenced by the given threads is
 * present in the world (hydrating from prod where possible) and strips refs
 * that no longer resolve so buildCorpusFiles' strict checks cannot trip on
 * deleted rows. Mutates `world` and the threads in place; returns log lines.
 */
async function ensureReferencedEntities(
  client: PgClient,
  world: ExtractedWorld,
  threads: ExtractedThread[]
): Promise<string[]> {
  const log: string[] = [];

  // Connections first (their actors feed the contact pass).
  const knownConnections = new Set(world.connections.map((c) => c.id));
  const neededConnections = [
    ...new Set(
      threads
        .map((t) => t.connectionId)
        .filter((id): id is string => id !== null && !knownConnections.has(id))
    ),
  ];
  if (neededConnections.length > 0) {
    const { connections, missing } = await loadConnections(
      client,
      neededConnections
    );
    world.connections.push(...connections);
    if (connections.length > 0) {
      log.push(`hydrated ${connections.length} thread-referenced connection(s)`);
    }
    if (missing.length > 0) {
      log.push(
        `${missing.length} connection id(s) no longer exist in prod (no twist_instance row) — affected threads emit without a connection`
      );
    }
  }

  const knownContacts = new Set(world.contacts.map((c) => c.id));
  const neededContacts = new Set<string>();
  for (const t of threads) {
    for (const id of t.contacts) if (!knownContacts.has(id)) neededContacts.add(id);
    if (t.authorContactId && !knownContacts.has(t.authorContactId)) {
      neededContacts.add(t.authorContactId);
    }
  }
  for (const conn of world.connections) {
    // Tic-less connections (actorContactId null) have no real actor to
    // hydrate — emit synthesizes their placeholder contact.
    if (conn.actorContactId !== null && !knownContacts.has(conn.actorContactId)) {
      neededContacts.add(conn.actorContactId);
    }
  }
  if (neededContacts.size > 0) {
    const fetched = await loadContactsByIds(client, world.userId, [
      ...neededContacts,
    ]);
    world.contacts.push(...fetched);
    for (const c of fetched) knownContacts.add(c.id);
    log.push(`hydrated ${fetched.length} additional contact(s)`);
    const unresolved = [...neededContacts].filter((id) => !knownContacts.has(id));
    if (unresolved.length > 0) {
      const gone = new Set(unresolved);
      for (const t of threads) {
        t.contacts = t.contacts.filter((id) => !gone.has(id));
        if (t.authorContactId && gone.has(t.authorContactId)) {
          t.authorContactId = null;
        }
      }
      world.connections = world.connections.filter(
        (c) => c.actorContactId === null || !gone.has(c.actorContactId)
      );
      log.push(
        `${unresolved.length} contact id(s) no longer exist in prod — refs dropped`
      );
    }
  }

  const knownGroups = new Set(world.groups.map((g) => g.id));
  const neededGroups = new Set<string>();
  for (const t of threads) {
    for (const id of t.groups) if (!knownGroups.has(id)) neededGroups.add(id);
  }
  if (neededGroups.size > 0) {
    const fetched = await loadGroupsByIds(client, [...neededGroups]);
    world.groups.push(...fetched);
    for (const g of fetched) knownGroups.add(g.id);
    log.push(`hydrated ${fetched.length} additional group(s)`);
    const unresolved = [...neededGroups].filter((id) => !knownGroups.has(id));
    if (unresolved.length > 0) {
      const gone = new Set(unresolved);
      for (const t of threads) {
        t.groups = t.groups.filter((id) => !gone.has(id));
      }
      log.push(
        `${unresolved.length} group id(s) no longer exist in prod — refs dropped`
      );
    }
  }

  return log;
}

async function main() {
  const opts = parseOpts();
  const client = new pg.Client({ connectionString: opts.dbUrl });
  await client.connect();
  try {
    if (opts.listActive) {
      const rows = await listActiveUsers(client);
      console.log("user_id                               tp_rows  user_moved");
      for (const r of rows) {
        console.log(
          `${r.userId}  ${String(r.threadPriorityCount).padStart(7)}  ${String(r.userMovedCount).padStart(10)}`
        );
      }
      return;
    }

    const userId =
      opts.userId ?? (await resolveUserIdByEmail(client, opts.userEmail!));
    console.log(`Extracting user ${userId}`);

    const world = await loadWorldEntities(client, userId);
    const activePriorityIds = new Set(world.priorities.map((p) => p.id));

    // Training set: all user_moved threads filed in active priorities.
    const allTrainings = await loadTrainingThreads(client, userId);
    const trainings = allTrainings.filter(
      (t) => t.filedToPriority !== null && activePriorityIds.has(t.filedToPriority)
    );
    if (trainings.length < allTrainings.length) {
      console.log(
        `  dropped ${allTrainings.length - trainings.length} training threads filed in archived priorities`
      );
    }
    const { training, holdout } = splitHoldout(trainings, opts.holdoutRecentMoves);

    // Negatives (real timestamps); threads not in the emitted training set —
    // including holdout threads — are hydrated as negative_threads.
    const allNegatives = await loadNegatives(client, userId);
    const negatives = allNegatives.filter((n) =>
      activePriorityIds.has(n.priorityId)
    );
    if (negatives.length < allNegatives.length) {
      console.log(
        `  dropped ${allNegatives.length - negatives.length} negatives pointing at archived priorities`
      );
    }
    const trainingIds = new Set(training.map((t) => t.id));
    const negativeThreads = await hydrateThreadsByIds(client, userId, [
      ...new Set(
        negatives.map((n) => n.threadId).filter((id) => !trainingIds.has(id))
      ),
    ]);

    // Refresh-preserving-labels over the existing cases.yaml.
    const scriptDir = dirname(fileURLToPath(import.meta.url));
    const corpusDir = resolve(scriptDir, "..", "..", "corpora", opts.out!);
    const existingWorldYaml = await readOptional(join(corpusDir, "world.yaml"));
    const existingEmbeddingsYaml = await readOptional(
      join(corpusDir, "embeddings.yaml")
    );
    const existingCasesText = await readOptional(join(corpusDir, "cases.yaml"));
    const existingCases: Record<string, unknown>[] = existingCasesText
      ? (((parseYaml(existingCasesText) as Record<string, unknown>)?.cases ??
          []) as Record<string, unknown>[])
      : [];
    const resolution = await resolveExistingCases(client, userId, existingCases);
    const merged = mergeExistingCases(existingCases, resolution);
    for (const line of merged.report) console.log(`  ${line}`);
    if (existingCases.length > 0) {
      console.log(
        `  refreshed ${existingCases.length} existing cases (${merged.resolvedThreadIds.size} re-hydrated, labels preserved)`
      );
    }

    // Top up with fresh sampled cases.
    const exclude = new Set<string>([
      ...trainingIds,
      ...holdout.map((t) => t.id),
      ...merged.resolvedThreadIds,
    ]);
    const sampleCount =
      opts.timelineCases !== null
        ? opts.timelineCases
        : Math.max(0, opts.caseCount - merged.entries.length);
    const sampledIds =
      opts.timelineCases !== null
        ? await sampleTimelineCaseThreadIds(
            client,
            userId,
            sampleCount,
            exclude,
            activePriorityIds
          )
        : await sampleStratifiedCaseThreadIds(
            client,
            userId,
            sampleCount,
            exclude,
            activePriorityIds
          );
    const sampled = await hydrateThreadsByIds(client, userId, sampledIds);

    const nowIso = new Date().toISOString();
    let nextN = merged.maxCaseNumber + 1;
    const sampledEntries = sampledCaseEntries(sampled, nextN, nowIso);
    nextN += sampledEntries.length;
    const holdoutEntries = holdoutCaseEntries(holdout, nextN, nowIso);
    const caseEntries = [...merged.entries, ...sampledEntries, ...holdoutEntries];

    // Make the world self-consistent for every thread we are about to emit.
    const mergedThreads = merged.entries.flatMap((e) =>
      e.kind === "thread" ? [e.thread] : []
    );
    const allThreads = [
      ...training,
      ...holdout,
      ...negativeThreads,
      ...mergedThreads,
      ...sampled,
    ];
    const completenessLog = await ensureReferencedEntities(
      client,
      world,
      allThreads
    );
    for (const line of completenessLog) console.log(`  ${line}`);

    const regenerateCommand =
      `pnpm exec tsx src/seeder/from-prod.ts --user-id ${userId} --out ${opts.out}` +
      ` --case-count ${opts.caseCount}` +
      (opts.holdoutRecentMoves > 0
        ? ` --holdout-recent-moves ${opts.holdoutRecentMoves}`
        : "") +
      (opts.timelineCases !== null
        ? ` --timeline-cases ${opts.timelineCases}`
        : "");

    const build = buildCorpusFiles({
      corpusName: opts.out!,
      world,
      trainings: training,
      negatives,
      negativeThreads,
      cases: caseEntries,
      existingWorldYaml,
      existingEmbeddingsYaml,
      allowNoteContentEmbeddings: NOTE_EMBEDDING_ALLOWED_EMAILS.has(
        world.userEmail
      ),
      regenerateCommand,
    });

    // Write the emitted files (replacing any pre-v2 per-case layout).
    await rm(join(corpusDir, "cases"), { recursive: true, force: true });
    await mkdir(join(corpusDir, "trainings"), { recursive: true });
    for (const f of build.files) {
      const path = join(corpusDir, f.path);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, f.text, "utf-8");
    }

    // Slug-migrate extra training files this seeder does not regenerate.
    if (build.slugMigration.size > 0) {
      const trainingFiles = (await readdir(join(corpusDir, "trainings"))).filter(
        (f) => /\.ya?ml$/.test(f) && f !== "full.yaml"
      );
      for (const file of trainingFiles) {
        const path = join(corpusDir, "trainings", file);
        const text = await readFile(path, "utf-8");
        const { text: rewritten, replacements } = applySlugMigrationToYamlText(
          text,
          build.slugMigration
        );
        if (replacements > 0) {
          await writeFile(path, rewritten, "utf-8");
          console.log(
            `  rewrote ${replacements} slug reference(s) in trainings/${file}`
          );
        }
      }
    }

    for (const line of build.report) console.log(`  ${line}`);
    if (build.warnings.length > 0) {
      console.log(
        `  ${build.warnings.length} leak-check warning(s) for manual audit (titles are verbatim by policy):`
      );
      for (const w of build.warnings.slice(0, 50)) {
        console.log(`    ${w.path}:${w.line} [${w.kind}] "${w.value}" — ${w.context}`);
      }
    }
    console.log(`Wrote corpus to ${corpusDir}`);
  } finally {
    await client.end();
  }
}

// Only run the CLI when executed directly (tests import resolveExistingCases).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
