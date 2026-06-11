#!/usr/bin/env tsx
/**
 * Local embedding backfill with parity gate (spec D).
 *
 * Fills `embedding_ref: null` on titled cases and training threads with
 * locally-computed bge-small-en-v1.5 vectors (`source: local-title`,
 * `embl-` ref prefix), appending them to the corpus's embeddings.yaml.
 *
 * A parity gate runs first whenever the corpus contains prod-extracted
 * (`emb-` prefixed) vectors: up to 5 `source: thread-title` vectors whose
 * owning entity's title is recoverable are re-embedded locally and compared
 * by cosine. ALL must be >= 0.99 or nothing is written — local vectors must
 * never mix with prod vectors when local inference demonstrably diverges
 * (and "parity not checkable" is conservatively treated as a failure).
 * Corpora with no prod vectors at all (synthetics) skip the gate.
 *
 * Usage:
 *   pnpm exec tsx src/seeder/gen-embeddings.ts --corpus <name> [--parity-only]
 *
 * `--corpus` accepts a name under libs/eval/corpora/ or a directory path
 * (anything containing a "/"). `--parity-only` runs the gate, prints the
 * cosines and PASS/FAIL, writes nothing, and exits 0 on pass / 2 on fail.
 */
import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

import { parse as parseYaml } from "yaml";

import { loadCorpus } from "../corpus/load";
import type { Corpus } from "../corpus/schema";
import { hashShort } from "./anonymize";
import { stringifyCorpusYaml } from "./emit";
import { embedTitle } from "./local-embedder";

// Loosely-typed YAML documents: this script edits existing files in place
// and must not strip fields it doesn't know about (same pattern as append.ts).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type YamlDoc = any;

export const PARITY_THRESHOLD = 0.99;
export const PARITY_SAMPLE_SIZE = 5;

// ===========================================================================
// Pure helpers (unit-tested; no model access)
// ===========================================================================

/** Cosine similarity. Throws on length mismatch; 0 when either norm is 0. */
export function cosine(a: number[], b: number[]): number {
  if (a.length !== b.length) {
    throw new Error(`cosine: vector length mismatch (${a.length} vs ${b.length})`);
  }
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    na += a[i]! * a[i]!;
    nb += b[i]! * b[i]!;
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

/**
 * Stable ref for a locally-embedded entity. The `embl-` prefix keeps local
 * provenance visible next to prod `emb-` refs (and deliberately does NOT
 * match a `startsWith("emb-")` prod check).
 */
export function localRef(sourceId: string): string {
  return `embl-${hashShort(sourceId, 10)}`;
}

export type FillEntry = {
  kind: "case" | "training";
  /** Corpus-relative file to update ("cases.yaml" or "trainings/<file>"). */
  file: string;
  /** Case id, or thread uuid for training/negative threads. */
  id: string;
  title: string;
  /** Allocated `embl-` ref. */
  ref: string;
};

export type ParityCandidate = { ref: string; title: string; vector: number[] };

export type FillPlan = {
  fills: FillEntry[];
  /** `source: thread-title` vectors whose owning entity's title is recoverable. */
  parityCandidates: ParityCandidate[];
  /** Corpus contains prod-extracted (`emb-` prefixed) vectors. */
  hasProdVectors: boolean;
  /**
   * Prod vectors present but parity is not checkable (zero candidates) —
   * conservatively treated as a parity failure, so nothing may be written.
   */
  blockedMixing: boolean;
};

export type RawTrainingFile = { file: string; raw: unknown };

/** Reads and YAML-parses every trainings/*.yaml file (sorted), like load.ts. */
export async function readTrainingDocs(
  rootDir: string
): Promise<RawTrainingFile[]> {
  const trainingsDir = join(rootDir, "trainings");
  let files: string[] = [];
  try {
    files = (await readdir(trainingsDir))
      .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"))
      .sort();
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    return [];
  }
  const out: RawTrainingFile[] = [];
  for (const file of files) {
    out.push({
      file,
      raw: parseYaml(await readFile(join(trainingsDir, file), "utf-8")),
    });
  }
  return out;
}

/**
 * Plans the backfill for a corpus:
 *
 * - `fills`: every case candidate and training/negative thread with
 *   `embedding_ref: null` and a non-empty title. Refs are allocated from a
 *   stable hash input — the case's source_thread_id (falling back to the
 *   case id), or the thread's own id — so re-runs and re-extractions
 *   allocate identical refs.
 * - `parityCandidates`: up to PARITY_SAMPLE_SIZE `source: thread-title`
 *   vectors whose owning entity (case or training/negative thread) still
 *   carries the title that was embedded.
 *
 * Training fills are planned from the raw YAML docs (not the normalized
 * Corpus) so each fill knows which trainings/*.yaml file to rewrite.
 */
export function planFill(
  corpus: Corpus,
  trainingFiles: RawTrainingFile[]
): FillPlan {
  const fills: FillEntry[] = [];

  for (const cs of corpus.cases) {
    if (cs.candidate.embedding_ref !== null) continue;
    if (!cs.candidate.title.trim()) continue;
    fills.push({
      kind: "case",
      file: "cases.yaml",
      id: cs.id,
      title: cs.candidate.title,
      ref: localRef(cs.sourceThreadId ?? cs.id),
    });
  }

  for (const tf of trainingFiles) {
    const doc = tf.raw as {
      threads?: unknown;
      negative_threads?: unknown;
    } | null;
    for (const key of ["threads", "negative_threads"] as const) {
      const arr = doc?.[key];
      if (!Array.isArray(arr)) continue;
      for (const t of arr as {
        id?: unknown;
        title?: unknown;
        embedding_ref?: unknown;
      }[]) {
        if (typeof t?.id !== "string" || typeof t?.title !== "string") continue;
        if (t.embedding_ref !== null && t.embedding_ref !== undefined) continue;
        if (!t.title.trim()) continue;
        fills.push({
          kind: "training",
          file: `trainings/${tf.file}`,
          id: t.id,
          title: t.title,
          ref: localRef(t.id),
        });
      }
    }
  }

  // Title recovery: ref -> owning entity's title, from cases AND trainings.
  const titleByRef = new Map<string, string>();
  const addTitle = (ref: string | null, title: string): void => {
    if (!ref || !title.trim() || titleByRef.has(ref)) return;
    titleByRef.set(ref, title);
  };
  for (const cs of corpus.cases) {
    addTitle(cs.candidate.embedding_ref, cs.candidate.title);
  }
  for (const ts of corpus.trainingSets) {
    for (const t of ts.threads) addTitle(t.embedding_ref, t.title);
    for (const t of ts.negativeThreads) addTitle(t.embedding_ref, t.title);
  }

  const hasProdVectors = [...corpus.embeddings.keys()].some((r) =>
    r.startsWith("emb-")
  );

  const parityCandidates: ParityCandidate[] = [];
  for (const e of corpus.embeddings.values()) {
    if (parityCandidates.length >= PARITY_SAMPLE_SIZE) break;
    if (e.source !== "thread-title") continue;
    const title = titleByRef.get(e.ref);
    if (!title) continue;
    parityCandidates.push({ ref: e.ref, title, vector: e.vector });
  }

  return {
    fills,
    parityCandidates,
    hasProdVectors,
    blockedMixing: hasProdVectors && parityCandidates.length === 0,
  };
}

// ===========================================================================
// Parity gate
// ===========================================================================

export type ParityOutcome = {
  /**
   * pass/fail: gate ran. skipped: no prod vectors, gate not applicable.
   * not-checkable: prod vectors present but zero candidates — treated as
   * fail for mixing purposes (conservative).
   */
  status: "pass" | "fail" | "skipped" | "not-checkable";
  results: { ref: string; title: string; cosine: number }[];
};

export async function runParityGate(
  plan: FillPlan,
  embed: (text: string) => Promise<number[]>
): Promise<ParityOutcome> {
  if (!plan.hasProdVectors) return { status: "skipped", results: [] };
  if (plan.parityCandidates.length === 0) {
    return { status: "not-checkable", results: [] };
  }
  const results: ParityOutcome["results"] = [];
  for (const c of plan.parityCandidates) {
    const local = await embed(c.title);
    results.push({ ref: c.ref, title: c.title, cosine: cosine(local, c.vector) });
  }
  const pass = results.every((r) => r.cosine >= PARITY_THRESHOLD);
  return { status: pass ? "pass" : "fail", results };
}

// ===========================================================================
// File updates (parse -> mutate -> stringify, the append.ts pattern; all
// texts are built before anything is written)
// ===========================================================================

async function applyFill(
  corpusDir: string,
  plan: FillPlan,
  newEmbeddings: { ref: string; source: "local-title"; vector: number[] }[]
): Promise<void> {
  const writes: { path: string; text: string }[] = [];

  // embeddings.yaml — append, preserving existing entries.
  const embeddingsPath = join(corpusDir, "embeddings.yaml");
  let embeddingsDoc: YamlDoc = { embeddings: [] };
  try {
    embeddingsDoc = parseYaml(await readFile(embeddingsPath, "utf-8")) ?? {
      embeddings: [],
    };
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
  embeddingsDoc.embeddings ??= [];
  embeddingsDoc.embeddings.push(...newEmbeddings);
  if (newEmbeddings.length > 0) {
    writes.push({ path: embeddingsPath, text: stringifyCorpusYaml(embeddingsDoc) });
  }

  // cases.yaml — set candidate.embedding_ref by case id.
  const caseFills = plan.fills.filter((f) => f.kind === "case");
  if (caseFills.length > 0) {
    const casesPath = join(corpusDir, "cases.yaml");
    const casesDoc: YamlDoc = parseYaml(await readFile(casesPath, "utf-8"));
    const refByCaseId = new Map(caseFills.map((f) => [f.id, f.ref]));
    let applied = 0;
    for (const cs of casesDoc?.cases ?? []) {
      const ref = refByCaseId.get(String(cs?.id));
      if (ref === undefined || !cs.candidate) continue;
      cs.candidate.embedding_ref = ref;
      applied++;
    }
    if (applied !== caseFills.length) {
      throw new Error(
        `gen-embeddings: planned ${caseFills.length} case fill(s) but matched ${applied} in cases.yaml — aborting before any write`
      );
    }
    writes.push({ path: casesPath, text: stringifyCorpusYaml(casesDoc) });
  }

  // trainings/*.yaml — set embedding_ref by thread id, per file.
  const trainingFillsByFile = new Map<string, FillEntry[]>();
  for (const f of plan.fills) {
    if (f.kind !== "training") continue;
    const list = trainingFillsByFile.get(f.file) ?? [];
    list.push(f);
    trainingFillsByFile.set(f.file, list);
  }
  for (const [file, fillList] of trainingFillsByFile) {
    const path = join(corpusDir, file);
    const doc: YamlDoc = parseYaml(await readFile(path, "utf-8"));
    const refByThreadId = new Map(fillList.map((f) => [f.id, f.ref]));
    let applied = 0;
    for (const key of ["threads", "negative_threads"]) {
      for (const t of doc?.[key] ?? []) {
        const ref = refByThreadId.get(String(t?.id));
        if (ref === undefined) continue;
        // Only fill where the plan saw null (same predicate as planFill).
        if (t.embedding_ref !== null && t.embedding_ref !== undefined) continue;
        t.embedding_ref = ref;
        applied++;
      }
    }
    if (applied !== fillList.length) {
      throw new Error(
        `gen-embeddings: planned ${fillList.length} training fill(s) in ${file} but matched ${applied} — aborting before any write`
      );
    }
    writes.push({ path, text: stringifyCorpusYaml(doc) });
  }

  for (const w of writes) {
    await writeFile(w.path, w.text, "utf-8");
  }
}

// ===========================================================================
// CLI
// ===========================================================================

function truncate(s: string, n: number): string {
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      corpus: { type: "string" },
      "parity-only": { type: "boolean" },
    },
  });
  if (!values.corpus) {
    console.error(
      "Usage: gen-embeddings --corpus <name-or-dir> [--parity-only]"
    );
    process.exit(2);
  }

  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = values.corpus.includes("/")
    ? resolve(process.cwd(), values.corpus)
    : resolve(scriptDir, "..", "..", "corpora", values.corpus);

  const corpus = await loadCorpus(corpusDir);
  const trainingFiles = await readTrainingDocs(corpusDir);
  const plan = planFill(corpus, trainingFiles);

  const caseFillCount = plan.fills.filter((f) => f.kind === "case").length;
  console.log(
    `Corpus ${corpus.name}: ${plan.fills.length} fill candidate(s) ` +
      `(${caseFillCount} case(s), ${plan.fills.length - caseFillCount} training thread(s)); ` +
      `${corpus.embeddings.size} existing embedding(s), prod (emb-) vectors: ${plan.hasProdVectors ? "yes" : "no"}.`
  );

  const parity = await runParityGate(plan, embedTitle);
  switch (parity.status) {
    case "skipped":
      console.log(
        "Parity gate: skipped — corpus has no prod (emb-) vectors; parity not applicable."
      );
      break;
    case "not-checkable":
      console.log(
        "Parity gate: NOT CHECKABLE — prod (emb-) vectors are present but no " +
          "`source: thread-title` vector has a recoverable title. Treating as FAIL (conservative)."
      );
      break;
    default:
      for (const r of parity.results) {
        console.log(
          `  cosine ${r.cosine.toFixed(6)}  ${r.ref}  "${truncate(r.title, 60)}"`
        );
      }
      console.log(
        `Parity gate: ${parity.status === "pass" ? "PASS" : "FAIL"} ` +
          `(threshold ${PARITY_THRESHOLD}, ${parity.results.length} candidate(s))`
      );
  }

  const parityFailed =
    parity.status === "fail" || parity.status === "not-checkable";

  if (values["parity-only"]) {
    process.exit(parityFailed ? 2 : 0);
  }

  if (parityFailed) {
    // The gate only runs when prod vectors exist, so a failure here always
    // means mixing — a uniformly-local/empty corpus takes the "skipped" path
    // above and proceeds.
    console.error(
      "blocked: would mix local vectors with prod vectors after parity failure — nothing written"
    );
    process.exit(2);
  }

  if (plan.fills.length === 0) {
    console.log(
      "Nothing to fill — every titled case/training thread already has an embedding_ref."
    );
    return;
  }

  // Embed each unique ref once (a thread appearing in multiple training
  // files, or as both a case source and a training thread, shares one ref).
  const toEmbed = new Map<string, string>();
  for (const f of plan.fills) {
    if (corpus.embeddings.has(f.ref) || toEmbed.has(f.ref)) continue;
    toEmbed.set(f.ref, f.title);
  }
  const newEmbeddings: { ref: string; source: "local-title"; vector: number[] }[] =
    [];
  for (const [ref, title] of toEmbed) {
    newEmbeddings.push({ ref, source: "local-title", vector: await embedTitle(title) });
  }

  await applyFill(corpusDir, plan, newEmbeddings);

  console.log(
    `Filled ${plan.fills.length} embedding_ref(s) (${caseFillCount} case(s), ` +
      `${plan.fills.length - caseFillCount} training thread(s)); appended ` +
      `${newEmbeddings.length} local-title vector(s) to embeddings.yaml.`
  );
}

// Only run the CLI when executed directly (tests import the pure helpers).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
