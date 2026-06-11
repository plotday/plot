#!/usr/bin/env tsx
/**
 * LLM gold-label proposals (spec H).
 *
 * For every case with `labels.gold: null`, asks Gemini (same eval LLM client
 * + file cache as the classifiers, but its OWN promptId — `propose-gold-v1`
 * — so cache entries cannot collide with classifier prompts) to pick the
 * priority where this user would file the thread, given the world's priority
 * tree and a sample of the corpus's training filings.
 *
 * Proposals are written back into cases.yaml as
 * `gold: <priority slug>` + `gold_rationale: "[llm] …"` +
 * `gold_source: llm-proposed`. Human labels are NEVER overwritten — only
 * `gold: null` cases are touched, and no `--force` flag exists. A null
 * answer leaves the case unlabeled and appends a `propose-gold: LLM
 * declined (…)` note. Every proposal is printed as an audit table for the
 * final report.
 *
 * Usage:
 *   pnpm exec tsx src/seeder/propose-gold.ts --corpus <name-or-dir>
 *
 * `--corpus` accepts a name under libs/eval/corpora/ or a directory path
 * (anything containing a "/"). Requires GOOGLE_GENERATIVE_AI_API_KEY (or
 * GEMINI_API_KEY); responses are cached under .cache/llm/propose-gold.
 */
import { readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

import { parse as parseYaml } from "yaml";

import { DEFAULTS_LLM } from "@plotday/classifier";

import { cachedLlmClient } from "../classifiers/llm-cache";
import { makeGeminiClient, type LLMClient } from "../classifiers/llm-client";
import { loadCorpus } from "../corpus/load";
import type {
  Corpus,
  CorpusCase,
  CorpusTrainingSet,
  CorpusWorld,
} from "../corpus/schema";
import { stringifyCorpusYaml } from "./emit";

// Loosely-typed YAML document: this script edits cases.yaml in place and
// must not strip fields it doesn't know about (same pattern as append.ts /
// gen-embeddings.ts).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type YamlDoc = any;

/**
 * Own prompt template id: hashInputs() folds this into every cache key, so
 * propose-gold replays can never collide with classifier cache entries
 * ("tiebreaker-v3" / "coldstart-v3" / "topic-ambiguity-v3").
 */
export const PROPOSE_GOLD_PROMPT_ID = "propose-gold-v1";

/** Max training exemplars included in the prompt (evenly sampled beyond). */
export const MAX_EXEMPLARS = 30;

export type Proposal = {
  /** World priority id, or null when the LLM declined (or went out-of-set). */
  priorityId: string | null;
  rationale: string;
};

const SYSTEM_PROMPT = [
  "You label evaluation cases for a thread classifier benchmark.",
  "You are given one user's priority tree (their projects and folders), examples of where that user filed past threads, and one candidate thread.",
  "Choose the priority where this user would file the candidate thread: answer with that priority's id from the tree, or null when no priority fits.",
  "Judge by the user's demonstrated filing behavior in the examples, not by generic plausibility. Keep the rationale to one short sentence.",
].join("\n");

// ===========================================================================
// Pure helpers (unit-tested; no LLM, no file IO)
// ===========================================================================

/**
 * Evenly samples up to `max` items, always including the first and last
 * (indices round i*(n-1)/(max-1), strictly increasing whenever n > max).
 */
export function sampleEvenly<T>(items: T[], max: number): T[] {
  if (items.length <= max) return [...items];
  if (max <= 0) return [];
  if (max === 1) return [items[0]!];
  const last = items.length - 1;
  const out: T[] = [];
  let prev = -1;
  for (let i = 0; i < max; i++) {
    const idx = Math.round((i * last) / (max - 1));
    if (idx === prev) continue; // unreachable when items.length > max; safety
    prev = idx;
    out.push(items[idx]!);
  }
  return out;
}

/**
 * Builds the propose-gold prompt: priority tree (id/title/description/path,
 * imitating the cold-start line rendering), up to MAX_EXEMPLARS training
 * filings, then the candidate. allowedPriorityIds is the FULL world priority
 * set — the response must name one of them or null.
 */
export function buildProposePrompt(
  world: CorpusWorld,
  trainingSet: CorpusTrainingSet,
  candidate: CorpusCase["candidate"]
): { system: string; user: string; allowedPriorityIds: string[] } {
  const lines: string[] = [];

  lines.push(`Priority tree (${world.priorities.length} priorities):`);
  for (const p of world.priorities) {
    const breadcrumb = p.path.replace(/\./g, " > ");
    lines.push(
      `- id: ${p.id}  title: ${p.title}${p.description ? `  description: ${p.description}` : ""}  path: ${breadcrumb}${p.key ? `  key: ${p.key}` : ""}`
    );
  }
  lines.push("");

  const titleById = new Map(world.priorities.map((p) => [p.id, p.title]));
  const exemplars = sampleEvenly(trainingSet.threads, MAX_EXEMPLARS);
  lines.push(
    `Past filings by this user (${exemplars.length} of ${trainingSet.threads.length} on record):`
  );
  for (const t of exemplars) {
    lines.push(
      // Include the id so the model can answer without cross-referencing the
      // tree listing (the response must be a priority id, not a title).
      `- "${t.title}" → ${titleById.get(t.filedToPriority) ?? t.filedToPriority} (id: ${t.filedToPriority})`
    );
  }
  lines.push("");

  lines.push("Candidate thread:");
  lines.push(`  title: ${candidate.title}`);
  lines.push(`  topic: ${candidate.topic ?? "(none)"}`);
  lines.push(`  contacts: ${candidate.contacts.length}`);
  const hasAuthor =
    candidate.authorContactId !== null || candidate.createdByOverride !== null;
  lines.push(`  author: ${hasAuthor ? "present" : "absent"}`);
  if (candidate.facets && Object.keys(candidate.facets).length > 0) {
    lines.push(
      `  facets: ${Object.entries(candidate.facets)
        .map(([k, v]) => `${k}=${v}`)
        .join(", ")}`
    );
  }

  return {
    system: SYSTEM_PROMPT,
    user: lines.join("\n"),
    allowedPriorityIds: world.priorities.map((p) => p.id),
  };
}

/** Exemplars come from the `full` training set, falling back to the first. */
export function pickTrainingSet(corpus: Corpus): CorpusTrainingSet {
  const ts =
    corpus.trainingSets.find((s) => s.name === "full") ??
    corpus.trainingSets[0];
  if (!ts) {
    throw new Error(`corpus "${corpus.name}" has no training sets`);
  }
  return ts;
}

/**
 * Collects a proposal for every `gold: null` case. Out-of-set responses
 * (possible from cache replays or test fakes — the live client already
 * guards this) become null-declines with an `out-of-set: <id>` rationale so
 * the audit trail records what the model actually said.
 */
export async function proposeForCases(
  corpus: Corpus,
  client: LLMClient
): Promise<Map<string, Proposal>> {
  const trainingSet = pickTrainingSet(corpus);
  const proposals = new Map<string, Proposal>();
  for (const cs of corpus.cases) {
    if (cs.labels.gold !== null) continue;
    const prompt = buildProposePrompt(corpus.world, trainingSet, cs.candidate);
    const output = await client.classify(prompt);
    let priorityId = output.priorityId;
    let rationale = output.rationale;
    if (priorityId !== null && !prompt.allowedPriorityIds.includes(priorityId)) {
      rationale = `out-of-set: ${priorityId}`;
      priorityId = null;
    }
    proposals.set(cs.id, { priorityId, rationale });
  }
  return proposals;
}

/**
 * Mutates the raw cases.yaml document in place:
 *
 * - Cases whose `labels.gold` is already set are NEVER touched (counted in
 *   `skippedLabeled`) — human labels survive every run, no --force exists.
 * - A non-null proposal writes `gold: <slug>` (id resolved through
 *   `slugByPriorityId`, matching how cases.yaml stores refs),
 *   `gold_rationale: "[llm] …"` and `gold_source: llm-proposed`.
 * - A null proposal leaves the case unlabeled and appends a
 *   `propose-gold: LLM declined (…)` line to `notes`.
 * - Proposals whose priority id has no slug are skipped untouched and
 *   reported in `unresolved`.
 *
 * Returns `updated` = number of cases that received a gold label.
 */
export function applyProposals(
  rawCasesDoc: YamlDoc,
  proposals: Map<string, Proposal>,
  slugByPriorityId: Map<string, string>
): { updated: number; skippedLabeled: number; unresolved: string[] } {
  let updated = 0;
  let skippedLabeled = 0;
  const unresolved: string[] = [];

  for (const cs of rawCasesDoc?.cases ?? []) {
    const proposal = proposals.get(String(cs?.id));
    if (proposal === undefined) continue;

    const gold = cs.labels?.gold;
    if (gold !== null && gold !== undefined) {
      skippedLabeled++;
      continue;
    }

    if (proposal.priorityId === null) {
      const note = `propose-gold: LLM declined (${proposal.rationale})`;
      cs.notes = cs.notes ? `${cs.notes}\n${note}` : note;
      continue;
    }

    const slug = slugByPriorityId.get(proposal.priorityId);
    if (slug === undefined) {
      unresolved.push(String(cs.id));
      continue;
    }

    cs.labels ??= {};
    cs.labels.gold = slug;
    cs.labels.gold_rationale = `[llm] ${proposal.rationale}`;
    cs.labels.gold_source = "llm-proposed";
    updated++;
  }

  return { updated, skippedLabeled, unresolved };
}

// ===========================================================================
// CLI
// ===========================================================================

function oneLine(s: string, max: number): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: { corpus: { type: "string" } } });
  if (!values.corpus) {
    console.error("Usage: propose-gold --corpus <name-or-dir>");
    process.exit(2);
  }

  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = values.corpus.includes("/")
    ? resolve(process.cwd(), values.corpus)
    : resolve(scriptDir, "..", "..", "corpora", values.corpus);

  try {
    await stat(join(corpusDir, "world.yaml"));
  } catch {
    console.error(
      `propose-gold: no corpus found at ${corpusDir} (missing world.yaml). ` +
        "Pass a name under libs/eval/corpora/ or a corpus directory path."
    );
    process.exit(2);
  }

  const corpus = await loadCorpus(corpusDir);
  const unlabeled = corpus.cases.filter((c) => c.labels.gold === null);
  if (unlabeled.length === 0) {
    console.log(
      `Corpus ${corpus.name}: every case already has a gold label — nothing to propose.`
    );
    return;
  }

  const model = DEFAULTS_LLM.llm?.model;
  if (!model) throw new Error("DEFAULTS_LLM.llm.model is not configured");
  const client = cachedLlmClient({
    client: makeGeminiClient(model),
    cacheDir: join(scriptDir, "..", "..", ".cache", "llm"),
    namespace: "propose-gold",
    promptTemplateId: PROPOSE_GOLD_PROMPT_ID,
  });

  console.log(
    `Corpus ${corpus.name}: proposing gold labels for ${unlabeled.length} ` +
      `unlabeled case(s) of ${corpus.cases.length} (model ${client.id}, ` +
      `promptId ${PROPOSE_GOLD_PROMPT_ID}).`
  );

  const proposals = await proposeForCases(corpus, client);

  const casesPath = join(corpusDir, "cases.yaml");
  const rawCasesDoc: YamlDoc = parseYaml(await readFile(casesPath, "utf-8"));
  const slugByPriorityId = new Map(
    corpus.world.priorities.map((p) => [p.id, p.slug])
  );
  const result = applyProposals(rawCasesDoc, proposals, slugByPriorityId);
  await writeFile(casesPath, stringifyCorpusYaml(rawCasesDoc), "utf-8");

  // Audit table: one row per consulted case, for Kris's review in the
  // final report.
  const proposedLabel = (p: Proposal): string =>
    p.priorityId === null
      ? "(declined)"
      : (slugByPriorityId.get(p.priorityId) ??
        `(unresolved: ${p.priorityId.slice(0, 8)})`);
  const rows = corpus.cases
    .filter((cs) => proposals.has(cs.id))
    .map((cs) => {
      const p = proposals.get(cs.id)!;
      return { id: cs.id, proposed: proposedLabel(p), rationale: p.rationale };
    });
  const idW = Math.max(4, ...rows.map((r) => r.id.length));
  const slugW = Math.max(8, ...rows.map((r) => r.proposed.length));
  console.log("");
  console.log("AUDIT — gold-label proposals (gold_source: llm-proposed)");
  console.log(`${"case".padEnd(idW)} | ${"proposed".padEnd(slugW)} | rationale`);
  console.log(`${"-".repeat(idW)}-+-${"-".repeat(slugW)}-+-${"-".repeat(40)}`);
  for (const r of rows) {
    console.log(
      `${r.id.padEnd(idW)} | ${r.proposed.padEnd(slugW)} | ${oneLine(r.rationale, 80)}`
    );
  }
  console.log("");

  const declined = [...proposals.values()].filter(
    (p) => p.priorityId === null
  ).length;
  console.log(
    `Wrote ${result.updated} gold label(s); ${declined} decline(s) noted; ` +
      `${result.skippedLabeled} already-labeled case(s) untouched; ` +
      `${result.unresolved.length} unresolved priority id(s)` +
      `${result.unresolved.length > 0 ? ` (${result.unresolved.join(", ")})` : ""}. ` +
      `LLM cache: ${client.stats.hits} hit(s), ${client.stats.misses} miss(es).`
  );
}

// Only run the CLI when executed directly (tests import the pure helpers).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
