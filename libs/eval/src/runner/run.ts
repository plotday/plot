import { getClassifier } from "../classifiers/registry";
import type {
  ClassificationResult,
  ClassifierContext,
} from "@plotday/classifier";
import type { Corpus, CorpusCase, CorpusTrainingSet } from "../corpus/schema";
import { deterministicUuid } from "../corpus/hash";
import { loadCorpus } from "../corpus/load";
import { rankOfGold } from "../scoring/rank";
import {
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
            const result = await runOneCase(sandbox, corpus, ts, cs, classifierName);
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

async function runOneCase(
  sandbox: SandboxHandle,
  corpus: Corpus,
  trainingSet: CorpusTrainingSet,
  cs: CorpusCase,
  classifierName: string
): Promise<RunResult> {
  const classifier = getClassifier(classifierName);
  const emb = cs.candidate.embedding_ref
    ? corpus.embeddings.get(cs.candidate.embedding_ref)
    : null;
  const threadId = caseIdToUuid(cs.id);
  const selfExclusions = selfExclusionTargets(cs, trainingSet);

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
    trainingSizeAtCase: trainingSet.threads.length - selfExclusions.length,
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
 * Training thread ids to archive for this case (spec A3a). source_thread_id
 * matches by full equality; pre-v2 cases fall back to the 8-hex prefix
 * embedded in the case id, matched via startsWith. Two training threads
 * sharing the same 8-hex prefix is theoretically possible — archive all
 * matches (the case still counts as one self-exclusion).
 */
function selfExclusionTargets(
  cs: CorpusCase,
  trainingSet: CorpusTrainingSet
): string[] {
  if (cs.sourceThreadId !== null) {
    const src = cs.sourceThreadId;
    return trainingSet.threads.filter((t) => t.id === src).map((t) => t.id);
  }
  const m = CASE_ID_PREFIX_RE.exec(cs.id);
  if (!m) return [];
  const prefix = m[1]!;
  return trainingSet.threads
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
