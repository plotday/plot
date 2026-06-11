import { getClassifier } from "../classifiers/registry";
import type {
  ClassificationResult,
  ClassifierContext,
} from "@plotday/classifier";
import type {
  Corpus,
  CorpusCase,
  CorpusNegative,
  CorpusTrainingSet,
  CorpusTrainingThread,
} from "../corpus/schema";
import { deterministicUuid } from "../corpus/hash";
import { loadCorpus } from "../corpus/load";
import { rankOfGold } from "../scoring/rank";
import {
  insertNegatives,
  insertTrainingThreads,
  loadTrainingSet,
  loadWorld,
  openSandbox,
  stageCandidate,
  type SandboxHandle,
} from "../sandbox/pg-sandbox";

export type RunResult = {
  corpus: string;
  caseId: string;
  classifier: string;
  trainingSet: string;
  predicted: string | null;
  stage: string;
  scores: Record<string, unknown>;
  durationMs: number;
  llmCalls: number;
  cacheHits: number;
  goldId: string | null;
  goldMatch: boolean | null;
  expectedId: string | null;
  expectedMatch: boolean | null;
  expectedStage: string | null;
  expectedStageMatch: boolean | null;
  /**
   * True when the case's source thread was found in the active training set
   * and archived for this case (anti-leakage guard, spec A3a).
   */
  selfExcluded: boolean;
  /** Active training thread count minus self-exclusions for this case. */
  trainingSizeAtCase: number;
  /** From ClassificationResult: an LLM stage was skipped for lack of budget. */
  budgetExhausted: boolean;
  /** Aggregate LLM token usage; null for classifiers without an LLM stage. */
  llmUsage: ClassificationResult["llmUsage"] | null;
  /** 1-based rank of the gold priority in the scoring ranking, when ranked. */
  rankOfGold: number | null;
  /** topScore − goldScore (0 when rank 1); null when unranked. */
  goldMargin: number | null;
  /** Case tags from the corpus, for per-tag report slices. */
  tags: string[];
  /** Gold-label provenance from the corpus; null when no gold label. */
  goldSource: "human" | "llm-proposed" | null;
};

export type RunSummary = {
  corpus: string;
  totalCases: number;
  perClassifierTraining: {
    classifier: string;
    trainingSet: string;
    goldAccuracy: number | null;
    /** Gold-evaluated cases answered correctly (Wilson CI numerator). */
    goldCorrect: number;
    /** Cases with a gold label (Wilson CI denominator). */
    goldEvaluated: number;
    expectedAccuracy: number | null;
    regressions: number;
    avgDurationMs: number;
    llmCallsPerCase: number;
    llmCacheHitRate: number | null;
  }[];
};

export type RunOptions = {
  corpusDir: string;
  classifiers: string[];
  databaseUrl?: string;
  /**
   * "matrix" (default): every selected training set × every case, exactly as
   * before. "backtest": time-replay (spec E) — exactly ONE training set
   * (named via trainingSets, default "full"), cases sorted by as_of, training
   * threads/negatives inserted progressively so each case sees only the
   * history that existed at its as_of.
   */
  mode?: "matrix" | "backtest";
  /** Optional filter: only run cases whose id matches. */
  caseFilter?: (caseId: string) => boolean;
  /** Optional filter: only run named training sets. Default = all. */
  trainingSets?: string[];
  /**
   * Cases carrying any of these tags are skipped. Defaults to
   * ["holdout-move"] — holdout cases must never leak into routine runs.
   * Pass [] to include everything (CLI: --include-holdout), or extend the
   * list to exclude more slices (CLI: --exclude-tags).
   */
  excludeTags?: string[];
};

export async function runEval(opts: RunOptions): Promise<{
  corpus: Corpus;
  results: RunResult[];
  summary: RunSummary;
}> {
  const corpus = await loadCorpus(opts.corpusDir);
  const excludeTags = new Set(opts.excludeTags ?? ["holdout-move"]);
  const afterTagFilter = corpus.cases.filter(
    (c) => !c.tags.some((t) => excludeTags.has(t))
  );
  const excludedByTag = corpus.cases.length - afterTagFilter.length;
  if (excludedByTag > 0) {
    // Visible in console output but off stdout, so --format json stays clean.
    console.error(
      `[eval] ${excludedByTag} case(s) excluded by tags (${[...excludeTags]
        .sort()
        .join(", ")}); pass --include-holdout (or excludeTags: []) to run them.`
    );
  }
  const cases = opts.caseFilter
    ? afterTagFilter.filter((c) => opts.caseFilter!(c.id))
    : afterTagFilter;

  if ((opts.mode ?? "matrix") === "backtest") {
    return runBacktest(opts, corpus, cases);
  }

  const selectedTrainingSets = opts.trainingSets
    ? corpus.trainingSets.filter((ts) => opts.trainingSets!.includes(ts.name))
    : corpus.trainingSets;
  if (selectedTrainingSets.length === 0) {
    throw new Error(
      `No training sets selected. Available: ${corpus.trainingSets.map((t) => t.name).join(", ")}`
    );
  }

  const sandbox = await openSandbox({ databaseUrl: opts.databaseUrl });
  try {
    await loadWorld(sandbox, corpus);
    const results: RunResult[] = [];
    for (const ts of selectedTrainingSets) {
      await sandbox.withSavepoint(`training_${sanitize(ts.name)}`, async () => {
        await loadTrainingSet(sandbox, corpus, ts);
        for (const cs of cases) {
          for (const classifierName of opts.classifiers) {
            const result = await runOneCase(
              sandbox,
              corpus,
              ts,
              ts.threads,
              cs,
              classifierName
            );
            results.push(result);
          }
        }
      });
    }
    return {
      corpus,
      results,
      summary: summarize(corpus, opts.classifiers, selectedTrainingSets, cases.length, results),
    };
  } finally {
    await sandbox.close();
  }
}

/**
 * Time-replay backtest (spec E): replays ONE training set chronologically so
 * the run traces the cold-start→warm accuracy trajectory. Cases sort by
 * as_of; before each case, training threads with movedAt <= as_of and
 * negatives with createdAt <= as_of that are not yet present are inserted in
 * the OUTER transaction (monotonic — never rolled back between cases). Each
 * case then runs inside its savepoint exactly as in matrix mode, including
 * the self-exclusion guard (computed against the inserted-so-far threads).
 *
 * Null-clock choices (kept deliberately simple):
 * - Cases without as_of cannot be placed on the timeline → SKIPPED, with a
 *   counted stderr warning.
 * - Training threads with movedAt null are ALWAYS PRESENT (inserted before
 *   the first case): a thread without a move time cannot be ordered, and
 *   dropping real training signal would understate warm accuracy. A stderr
 *   note reports the count.
 * - A negative's clock is its createdAt; when null it follows its thread:
 *   negatives on training threads inherit the thread's movedAt clock, and
 *   negatives on negativeThreads are always present (like null movedAt).
 * - A negativeThread row has no clock of its own — it is inserted together
 *   with the first negative that references it.
 */
async function runBacktest(
  opts: RunOptions,
  corpus: Corpus,
  cases: CorpusCase[]
): Promise<{ corpus: Corpus; results: RunResult[]; summary: RunSummary }> {
  if (opts.trainingSets && opts.trainingSets.length > 1) {
    throw new Error(
      `Backtest uses exactly one training set; got ${opts.trainingSets.length} (${opts.trainingSets.join(", ")}).`
    );
  }
  const setName = opts.trainingSets?.[0] ?? "full";
  const trainingSet = corpus.trainingSets.find((t) => t.name === setName);
  if (!trainingSet) {
    throw new Error(
      `Backtest training set "${setName}" not found. Available: ${corpus.trainingSets.map((t) => t.name).join(", ")}`
    );
  }

  const dated = cases.filter((c) => c.asOf !== null);
  const skipped = cases.length - dated.length;
  if (skipped > 0) {
    // stderr so --format json keeps a clean stdout.
    console.error(`backtest: skipped ${skipped} case(s) without as_of`);
  }
  // Array.prototype.sort is stable: as_of ties keep corpus order.
  const ordered = [...dated].sort(
    (a, b) => a.asOf!.getTime() - b.asOf!.getTime()
  );

  const alwaysThreads = trainingSet.threads.filter((t) => t.movedAt === null);
  if (alwaysThreads.length > 0) {
    console.error(
      `backtest: ${alwaysThreads.length} training thread(s) without moved_at treated as always present`
    );
  }
  const timedThreads = trainingSet.threads
    .filter((t) => t.movedAt !== null)
    .sort((a, b) => a.movedAt!.getTime() - b.movedAt!.getTime());

  // Effective clock for a negative: createdAt, else its training thread's
  // movedAt, else null (= always present; covers negativeThread references).
  const movedAtByThreadId = new Map(
    trainingSet.threads.map((t) => [t.id, t.movedAt])
  );
  // A negative whose explicit createdAt precedes its training thread's
  // movedAt inserts before the thread row exists. FK triggers are off under
  // replica role, so the row sits dangling — invisible to scoring (which
  // joins public.thread) — until the thread arrives. Benign, by design.
  const negClock = (n: CorpusNegative): Date | null =>
    n.createdAt ?? movedAtByThreadId.get(n.threadId) ?? null;
  const alwaysNegatives = trainingSet.negatives.filter(
    (n) => negClock(n) === null
  );
  const timedNegatives = trainingSet.negatives
    .filter((n) => negClock(n) !== null)
    .sort((a, b) => negClock(a)!.getTime() - negClock(b)!.getTime());

  const negativeThreadsById = new Map(
    trainingSet.negativeThreads.map((t) => [t.id, t])
  );
  const insertedNegThreadIds = new Set<string>();

  const sandbox = await openSandbox({ databaseUrl: opts.databaseUrl });
  try {
    await loadWorld(sandbox, corpus);

    // Inserts a negatives batch plus any referenced negativeThread rows that
    // are not in the DB yet (training-thread references insert on their own
    // movedAt clock and are intentionally not handled here).
    const insertNegativeBatch = async (batch: CorpusNegative[]) => {
      const threadRows = [];
      for (const n of batch) {
        const t = negativeThreadsById.get(n.threadId);
        if (t && !insertedNegThreadIds.has(t.id)) {
          insertedNegThreadIds.add(t.id);
          threadRows.push(t);
        }
      }
      await insertNegatives(sandbox, corpus, threadRows, batch);
    };

    // Unordered ("always present") rows go in before the first case.
    const insertedThreads: CorpusTrainingThread[] = [];
    await insertTrainingThreads(sandbox, corpus, alwaysThreads);
    insertedThreads.push(...alwaysThreads);
    await insertNegativeBatch(alwaysNegatives);

    let threadIdx = 0;
    let negativeIdx = 0;
    const results: RunResult[] = [];
    for (const cs of ordered) {
      const asOf = cs.asOf!.getTime();
      const threadBatch: CorpusTrainingThread[] = [];
      while (
        threadIdx < timedThreads.length &&
        timedThreads[threadIdx]!.movedAt!.getTime() <= asOf
      ) {
        threadBatch.push(timedThreads[threadIdx]!);
        threadIdx++;
      }
      await insertTrainingThreads(sandbox, corpus, threadBatch);
      insertedThreads.push(...threadBatch);

      const negativeBatch: CorpusNegative[] = [];
      while (
        negativeIdx < timedNegatives.length &&
        negClock(timedNegatives[negativeIdx]!)!.getTime() <= asOf
      ) {
        negativeBatch.push(timedNegatives[negativeIdx]!);
        negativeIdx++;
      }
      await insertNegativeBatch(negativeBatch);

      for (const classifierName of opts.classifiers) {
        results.push(
          await runOneCase(
            sandbox,
            corpus,
            trainingSet,
            insertedThreads,
            cs,
            classifierName
          )
        );
      }
    }

    return {
      corpus,
      results,
      summary: summarize(
        corpus,
        opts.classifiers,
        [trainingSet],
        ordered.length,
        results
      ),
    };
  } finally {
    await sandbox.close();
  }
}

async function runOneCase(
  sandbox: SandboxHandle,
  corpus: Corpus,
  trainingSet: CorpusTrainingSet,
  /**
   * Training threads currently present in the DB: the full set in matrix
   * mode, the inserted-so-far prefix in backtest mode. Drives both the
   * self-exclusion guard and trainingSizeAtCase.
   */
  activeThreads: CorpusTrainingThread[],
  cs: CorpusCase,
  classifierName: string
): Promise<RunResult> {
  const classifier = getClassifier(classifierName);
  const emb = cs.candidate.embedding_ref
    ? corpus.embeddings.get(cs.candidate.embedding_ref)
    : null;
  const threadId = caseIdToUuid(cs.id);
  const selfExclusions = selfExclusionTargets(cs, activeThreads);

  // Candidate `author` (thread.created_by as seen by the classifier):
  //   v1: pass createdByOverride EXACTLY as recorded — null stays null. The
  //       author signal historically saw null when a v1 case had no author,
  //       even though the staged DB row defaulted created_by to user.id, and
  //       the byte-exactness regression gates pin that behavior.
  //   v2: mirror prod, where author is hydrated from the DB row and is never
  //       null — connection (twist_instance) when present, else the user.
  const author =
    corpus.world.schemaVersion >= 2
      ? (cs.candidate.createdByOverride ??
        cs.candidate.connectionId ??
        corpus.world.user.id)
      : cs.candidate.createdByOverride;

  const result = await sandbox.withSavepoint(`case_${sanitize(cs.id)}`, async () => {
    // Self-exclusion guard (spec A3a, always on): a case whose source thread
    // is also a training thread would score sem≈1.0 against its own copy — a
    // leaked answer. Archive the match inside the case savepoint (the
    // neighbor query filters archived_at) so it is invisible for this case
    // only and remains training signal for every other case.
    for (const trainingThreadId of selfExclusions) {
      await sandbox.rawQuery(
        `UPDATE public.thread SET archived_at = now() WHERE id = $1`,
        [trainingThreadId]
      );
    }

    await stageCandidate(sandbox, corpus, {
      threadId,
      title: cs.candidate.title,
      topic: cs.candidate.topic,
      contacts: cs.candidate.contacts,
      groups: cs.candidate.groups,
      embedding: emb?.vector ?? null,
      authorContactId: cs.candidate.authorContactId,
      connectionId: cs.candidate.connectionId,
      createdByOverride: cs.candidate.createdByOverride,
      facets: cs.candidate.facets,
    });

    const ctx: ClassifierContext = {
      db: sandbox.db,
      rawQuery: sandbox.rawQuery,
      userId: corpus.world.user.id,
      schemaName: "public",
      corpusName: corpus.name,
    };

    return classifier.classify(ctx, {
      threadId,
      title: cs.candidate.title,
      topic: cs.candidate.topic,
      contacts: cs.candidate.contacts,
      groups: cs.candidate.groups,
      embedding: emb?.vector ?? null,
      author,
      // All null for v1 corpora by loader normalization (v1 unchanged).
      facets: cs.candidate.facets,
      authorContactId: cs.candidate.authorContactId,
      connectionId: cs.candidate.connectionId,
    });
  });

  const goldId = cs.labels.gold;
  const expectedId = cs.labels.expected;
  const expectedStage = cs.labels.expectedStage;
  const ranked = rankOfGold(result.scores ?? {}, goldId);

  return {
    corpus: corpus.name,
    caseId: cs.id,
    classifier: classifier.name,
    trainingSet: trainingSet.name,
    predicted: result.priorityId,
    stage: result.stage,
    scores: result.scores ?? {},
    durationMs: result.durationMs,
    llmCalls: result.llmCalls,
    cacheHits: result.cacheHits,
    goldId,
    goldMatch: goldId === null ? null : goldId === result.priorityId,
    expectedId,
    expectedMatch: expectedId === null ? null : expectedId === result.priorityId,
    expectedStage,
    expectedStageMatch:
      expectedStage === null ? null : expectedStage === result.stage,
    selfExcluded: selfExclusions.length > 0,
    trainingSizeAtCase: activeThreads.length - selfExclusions.length,
    budgetExhausted: result.budgetExhausted,
    llmUsage: result.llmUsage ?? null,
    rankOfGold: ranked?.rank ?? null,
    goldMargin: ranked?.margin ?? null,
    tags: cs.tags,
    goldSource: cs.labels.goldSource,
  };
}

/** Case-id fallback for cases without source_thread_id: `NNN-<8 hex chars>`. */
const CASE_ID_PREFIX_RE = /^\d+-([0-9a-f]{8})$/;

/**
 * Training thread ids to archive for this case (spec A3a), matched against
 * the threads currently present in the DB. source_thread_id matches by full
 * equality; pre-v2 cases fall back to the 8-hex prefix embedded in the case
 * id, matched via startsWith. Two training threads sharing the same 8-hex
 * prefix is theoretically possible — archive all matches (the case still
 * counts as one self-exclusion).
 */
function selfExclusionTargets(
  cs: CorpusCase,
  activeThreads: CorpusTrainingThread[]
): string[] {
  if (cs.sourceThreadId !== null) {
    const src = cs.sourceThreadId;
    return activeThreads.filter((t) => t.id === src).map((t) => t.id);
  }
  const m = CASE_ID_PREFIX_RE.exec(cs.id);
  if (!m) return [];
  const prefix = m[1]!;
  return activeThreads
    .filter((t) => t.id.startsWith(prefix))
    .map((t) => t.id);
}

function summarize(
  corpus: Corpus,
  classifiers: string[],
  trainingSets: CorpusTrainingSet[],
  totalCases: number,
  results: RunResult[]
): RunSummary {
  const perClassifierTraining: RunSummary["perClassifierTraining"] = [];
  for (const c of classifiers) {
    for (const ts of trainingSets) {
      const rows = results.filter(
        (r) => r.classifier === c && r.trainingSet === ts.name
      );
      const goldEval = rows.filter((r) => r.goldMatch !== null);
      const goldCorrect = goldEval.filter((r) => r.goldMatch).length;
      const expectedEval = rows.filter((r) => r.expectedMatch !== null);
      const totalLlm = rows.reduce((s, r) => s + r.llmCalls, 0);
      const totalHits = rows.reduce((s, r) => s + r.cacheHits, 0);
      const totalAttempts = totalLlm + totalHits;
      perClassifierTraining.push({
        classifier: c,
        trainingSet: ts.name,
        goldAccuracy: goldEval.length > 0 ? goldCorrect / goldEval.length : null,
        goldCorrect,
        goldEvaluated: goldEval.length,
        expectedAccuracy:
          expectedEval.length > 0
            ? expectedEval.filter((r) => r.expectedMatch).length /
              expectedEval.length
            : null,
        regressions: expectedEval.filter((r) => r.expectedMatch === false)
          .length,
        avgDurationMs:
          rows.length > 0
            ? rows.reduce((sum, r) => sum + r.durationMs, 0) / rows.length
            : 0,
        llmCallsPerCase: rows.length > 0 ? totalLlm / rows.length : 0,
        llmCacheHitRate: totalAttempts > 0 ? totalHits / totalAttempts : null,
      });
    }
  }
  return { corpus: corpus.name, totalCases, perClassifierTraining };
}

function sanitize(name: string): string {
  return name.replace(/[^A-Za-z0-9_]/g, "_");
}

/**
 * Maps a case id to a deterministic UUID for the candidate thread row. The
 * row only exists inside a savepoint so this UUID is not exposed externally;
 * we just need it stable across re-runs for debugging.
 */
function caseIdToUuid(caseId: string): string {
  return deterministicUuid(caseId);
}
