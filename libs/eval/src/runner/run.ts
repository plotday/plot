import { getClassifier } from "../classifiers/registry";
import type { ClassifierContext } from "@plotday/classifier";
import type { Corpus, CorpusCase, CorpusTrainingSet } from "../corpus/schema";
import { deterministicUuid } from "../corpus/hash";
import { loadCorpus } from "../corpus/load";
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
};

export type RunSummary = {
  corpus: string;
  totalCases: number;
  perClassifierTraining: {
    classifier: string;
    trainingSet: string;
    goldAccuracy: number | null;
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
};

export async function runEval(opts: RunOptions): Promise<{
  corpus: Corpus;
  results: RunResult[];
  summary: RunSummary;
}> {
  const corpus = await loadCorpus(opts.corpusDir);
  const cases = opts.caseFilter
    ? corpus.cases.filter((c) => opts.caseFilter!(c.id))
    : corpus.cases;
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

  const result = await sandbox.withSavepoint(`case_${sanitize(cs.id)}`, async () => {
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
      author: cs.candidate.createdByOverride,
      // The corpus model now carries facets / authorContactId / connectionId
      // (schema v2), but wiring them into classify() + stageCandidate is the
      // A4 runner task — keep them inert here so v1-era behavior is
      // byte-identical until that lands.
      facets: null,
      authorContactId: null,
      connectionId: null,
    });
  });

  const goldId = cs.labels.gold;
  const expectedId = cs.labels.expected;
  const expectedStage = cs.labels.expectedStage;

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
  };
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
      const expectedEval = rows.filter((r) => r.expectedMatch !== null);
      const totalLlm = rows.reduce((s, r) => s + r.llmCalls, 0);
      const totalHits = rows.reduce((s, r) => s + r.cacheHits, 0);
      const totalAttempts = totalLlm + totalHits;
      perClassifierTraining.push({
        classifier: c,
        trainingSet: ts.name,
        goldAccuracy:
          goldEval.length > 0
            ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
            : null,
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
