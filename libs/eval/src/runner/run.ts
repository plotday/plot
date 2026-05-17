import { getClassifier } from "../classifiers/registry";
import type { ClassifierContext } from "../classifiers/types";
import type { Corpus, CorpusCase } from "../corpus/schema";
import { loadCorpus } from "../corpus/load";
import {
  loadWorld,
  openSandbox,
  stageCandidate,
  type SandboxHandle,
} from "../sandbox/pg-sandbox";

export type RunResult = {
  corpus: string;
  caseId: string;
  classifier: string;
  predicted: string | null;
  stage: string;
  scores: Record<string, unknown>;
  durationMs: number;
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
  perClassifier: {
    classifier: string;
    goldAccuracy: number | null;
    expectedAccuracy: number | null;
    regressions: number;
    avgDurationMs: number;
  }[];
};

export type RunOptions = {
  corpusDir: string;
  classifiers: string[];
  databaseUrl?: string;
  /** Optional filter: only run cases whose id matches. */
  caseFilter?: (caseId: string) => boolean;
};

export async function runEval(opts: RunOptions): Promise<{
  results: RunResult[];
  summary: RunSummary;
}> {
  const corpus = await loadCorpus(opts.corpusDir);
  const sandbox = await openSandbox({ databaseUrl: opts.databaseUrl });
  try {
    await loadWorld(sandbox, corpus);
    const results: RunResult[] = [];
    const cases = opts.caseFilter
      ? corpus.cases.filter((c) => opts.caseFilter!(c.id))
      : corpus.cases;
    for (const cs of cases) {
      for (const classifierName of opts.classifiers) {
        const result = await runOneCase(sandbox, corpus, cs, classifierName);
        results.push(result);
      }
    }
    return { results, summary: summarize(corpus, opts.classifiers, results) };
  } finally {
    await sandbox.close();
  }
}

async function runOneCase(
  sandbox: SandboxHandle,
  corpus: Corpus,
  cs: CorpusCase,
  classifierName: string
): Promise<RunResult> {
  const classifier = getClassifier(classifierName);
  // Resolve embedding from refs.
  const emb = cs.candidate.embedding_ref
    ? corpus.embeddings.get(cs.candidate.embedding_ref)
    : null;
  // Generate a stable but unique thread_id for the case row, scoped to the
  // savepoint. Use a deterministic UUIDv5-like scheme by hashing the case id?
  // For simplicity we use a fixed prefix + counter; the row is gone after
  // ROLLBACK TO SAVEPOINT so collisions across cases are impossible.
  const threadId = caseIdToUuid(cs.id);

  const result = await sandbox.withSavepoint(`case_${cs.id}`, async () => {
    await stageCandidate(sandbox, corpus, {
      threadId,
      title: cs.candidate.title,
      topic: cs.candidate.topic,
      contacts: cs.candidate.contacts,
      groups: cs.candidate.groups,
      embedding: emb?.vector ?? null,
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
    });
  });

  const goldId = cs.labels.gold;
  const expectedId = cs.labels.expected;
  const expectedStage = cs.labels.expected_stage;

  return {
    corpus: corpus.name,
    caseId: cs.id,
    classifier: classifier.name,
    predicted: result.priorityId,
    stage: result.stage,
    scores: result.scores ?? {},
    durationMs: result.durationMs,
    goldId,
    goldMatch: goldId === null ? null : goldId === result.priorityId,
    expectedId,
    expectedMatch: expectedId === null ? null : expectedId === result.priorityId,
    expectedStage,
    expectedStageMatch: expectedStage === null ? null : expectedStage === result.stage,
  };
}

function summarize(
  corpus: Corpus,
  classifiers: string[],
  results: RunResult[]
): RunSummary {
  const perClassifier = classifiers.map((c) => {
    const rows = results.filter((r) => r.classifier === c);
    const goldEval = rows.filter((r) => r.goldMatch !== null);
    const expectedEval = rows.filter((r) => r.expectedMatch !== null);
    return {
      classifier: c,
      goldAccuracy:
        goldEval.length > 0
          ? goldEval.filter((r) => r.goldMatch).length / goldEval.length
          : null,
      expectedAccuracy:
        expectedEval.length > 0
          ? expectedEval.filter((r) => r.expectedMatch).length / expectedEval.length
          : null,
      regressions: expectedEval.filter((r) => r.expectedMatch === false).length,
      avgDurationMs:
        rows.length > 0
          ? rows.reduce((sum, r) => sum + r.durationMs, 0) / rows.length
          : 0,
    };
  });
  return { corpus: corpus.name, totalCases: results.length / classifiers.length, perClassifier };
}

/**
 * Maps a case id to a deterministic UUID for the candidate thread row. The
 * row only exists inside a savepoint so this UUID is not exposed externally;
 * we just need it stable across re-runs for debugging.
 */
function caseIdToUuid(caseId: string): string {
  // FNV-1a hash → 32 hex digits, formatted as UUID v4.
  let h1 = 0x811c9dc5;
  let h2 = 0xdeadbeef;
  for (let i = 0; i < caseId.length; i++) {
    h1 = (Math.imul(h1 ^ caseId.charCodeAt(i), 16777619) >>> 0);
    h2 = (Math.imul(h2 ^ caseId.charCodeAt(i), 2654435761) >>> 0);
  }
  const a = h1.toString(16).padStart(8, "0");
  const b = (h2 >>> 16).toString(16).padStart(4, "0");
  const c = ((h1 ^ h2) >>> 16).toString(16).padStart(4, "0");
  const d = (h2 & 0xffff).toString(16).padStart(4, "0");
  const e = ((Math.imul(h1, h2) >>> 0).toString(16) +
    (Math.imul(h1 ^ h2, 0x9e3779b1) >>> 0).toString(16))
    .padStart(12, "0")
    .slice(0, 12);
  return `${a}-${b}-4${c.slice(1)}-8${d.slice(1)}-${e}`;
}
