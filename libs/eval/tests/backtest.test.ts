import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import type { ClassificationResult } from "@plotday/classifier";
import { registerVariant } from "../src/classifiers/registry";
import { runEval } from "../src/runner/run";

const USER_ID = "ba000000-0000-4000-8000-000000000001";
const P_ROOT = "ba000000-0000-4000-8000-000000000010";
const P_TARGET = "ba000000-0000-4000-8000-000000000011";
const ANNA = "ba000000-0000-4000-8000-000000000020";
// Training thread ids deliberately do NOT share an 8-hex prefix with any case
// id below, so the self-exclusion fallback never fires in these tests.
const T0 = "aaaa0000-0000-4000-8000-000000000100";
const T1 = "aaaa1111-0000-4000-8000-000000000101";
const T2 = "bbbb2222-0000-4000-8000-000000000102";
const T3 = "cccc3333-0000-4000-8000-000000000103";
const NEG1 = "dddd4444-0000-4000-8000-000000000200";

const WORLD = `
name: backtest-fixture
schema_version: 2
source: { kind: handcrafted }
user:
  id: "${USER_ID}"
  email: "backtest-user@example.test"
priorities:
  - { slug: root, id: "${P_ROOT}", path: evalbacktest, title: Everything }
  - { slug: target, id: "${P_TARGET}", path: evalbacktest.target, title: Vendors }
contacts:
  - { slug: anna, id: "${ANNA}", email: "anna@backtest.test", linked_to_user: true }
`;

// T1 < T2 < T3 by moved_at; one negative-evidence thread whose negative lands
// between T2 and T3 on the timeline.
const TRAININGS_FULL = `
name: full
threads:
  - id: "${T1}"
    title: T1 January invoice
    contacts: [anna]
    filed_to_priority: target
    moved_at: "2026-01-10T00:00:00Z"
  - id: "${T2}"
    title: T2 February metrics
    contacts: [anna]
    filed_to_priority: target
    moved_at: "2026-02-10T00:00:00Z"
  - id: "${T3}"
    title: T3 March digest
    contacts: [anna]
    filed_to_priority: target
    moved_at: "2026-03-10T00:00:00Z"
negative_threads:
  - id: "${NEG1}"
    title: Marketing blast
    contacts: [anna]
negatives:
  - { thread: "${NEG1}", priority: target, source: moved_out, created_at: "2026-02-15T00:00:00Z" }
`;

// Same set plus T0 without moved_at: an unordered training thread must be
// treated as always present (inserted before the first case).
const TRAININGS_WITH_NULL_MOVED = TRAININGS_FULL.replace(
  "threads:",
  `threads:
  - id: "${T0}"
    title: T0 timeless thread
    contacts: [anna]
    filed_to_priority: target`
);

const CASES = `
cases:
  - id: "101-eeeeee01"
    as_of: "2026-01-15T00:00:00Z"
    candidate: { title: Case Jan }
    labels: {}
  - id: "102-eeeeee02"
    as_of: "2026-02-20T00:00:00Z"
    candidate: { title: Case Feb }
    labels: {}
  - id: "103-eeeeee03"
    as_of: "2026-04-01T00:00:00Z"
    candidate: { title: Case Apr }
    labels: {}
  - id: "104-eeeeee04"
    candidate: { title: Case NoAsOf }
    labels: {}
`;

async function writeCorpus(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-backtest-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(dir, rel);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
  }
  return dir;
}

function fixtureFiles(trainings: string = TRAININGS_FULL): Record<string, string> {
  return {
    "world.yaml": WORLD,
    "trainings/full.yaml": trainings,
    "cases.yaml": CASES,
  };
}

type Probe = {
  title: string | null;
  /** thread_priority rows with user_moved (training filings visible now). */
  userMoved: number;
  /** thread_priority_negative rows visible now. */
  negatives: number;
  /** Whether the NEG1 negative-evidence thread row exists yet. */
  negThreadPresent: boolean;
};

/**
 * Registers a capturing fake classifier that probes the sandbox DB at
 * classify time, recording how much training state each case can see.
 */
function registerProbe(name: string): Probe[] {
  const captured: Probe[] = [];
  registerVariant(name, {
    name,
    async classify(ctx, candidate): Promise<ClassificationResult> {
      const count = async (sql: string, values: unknown[]) =>
        (
          (await ctx.rawQuery(sql, values)) as { rows: { n: number }[] }
        ).rows[0]!.n;
      captured.push({
        title: candidate.title,
        userMoved: await count(
          `SELECT count(*)::int AS n FROM public.thread_priority
           WHERE user_id = $1 AND user_moved`,
          [ctx.userId]
        ),
        negatives: await count(
          `SELECT count(*)::int AS n FROM public.thread_priority_negative
           WHERE user_id = $1`,
          [ctx.userId]
        ),
        negThreadPresent:
          (await count(
            `SELECT count(*)::int AS n FROM public.thread WHERE id = $1`,
            [NEG1]
          )) > 0,
      });
      return {
        priorityId: null,
        stage: "none",
        scores: {},
        durationMs: 0,
        llmCalls: 0,
        cacheHits: 0,
        budgetExhausted: false,
      };
    },
  });
  return captured;
}

describe.runIf(!!process.env.DATABASE_URL)("backtest mode", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("replays the training timeline: each case sees only history before its as_of", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const probes = registerProbe("test:backtest-probe");
    const dir = await writeCorpus(fixtureFiles());

    const { results, summary } = await runEval({
      corpusDir: dir,
      classifiers: ["test:backtest-probe"],
      mode: "backtest",
      // trainingSets omitted: backtest defaults to "full".
    });

    // The null-as_of case is skipped (counted warning), the rest run in
    // chronological as_of order.
    expect(results.map((r) => r.caseId)).toEqual([
      "101-eeeeee01",
      "102-eeeeee02",
      "103-eeeeee03",
    ]);
    expect(errSpy.mock.calls.flat()).toContain(
      "backtest: skipped 1 case(s) without as_of"
    );

    // Progressive training growth: 1, then 2 (+ the negative filed 02-15),
    // then all 3.
    expect(probes.map((p) => p.title)).toEqual([
      "Case Jan",
      "Case Feb",
      "Case Apr",
    ]);
    expect(probes[0]).toMatchObject({
      userMoved: 1,
      negatives: 0,
      negThreadPresent: false,
    });
    expect(probes[1]).toMatchObject({
      userMoved: 2,
      negatives: 1,
      negThreadPresent: true,
    });
    expect(probes[2]).toMatchObject({ userMoved: 3, negatives: 1 });

    // RunResult bookkeeping: training size at case time, chosen set's name.
    expect(results.map((r) => r.trainingSizeAtCase)).toEqual([1, 2, 3]);
    for (const r of results) expect(r.trainingSet).toBe("full");
    expect(summary.totalCases).toBe(3);
  }, 60_000);

  it("matrix mode is untouched: all cases run and see the full training set", async () => {
    const probes = registerProbe("test:backtest-matrix-probe");
    const dir = await writeCorpus(fixtureFiles());

    const { results } = await runEval({
      corpusDir: dir,
      classifiers: ["test:backtest-matrix-probe"],
      trainingSets: ["full"],
    });

    // All 4 cases (incl. the null-as_of one) run in corpus order.
    expect(results).toHaveLength(4);
    expect(results.map((r) => r.caseId)).toContain("104-eeeeee04");
    for (const p of probes) {
      expect(p.userMoved).toBe(3);
      expect(p.negatives).toBe(1);
    }
    for (const r of results) expect(r.trainingSizeAtCase).toBe(3);
  }, 60_000);

  it("treats training threads without moved_at as always present", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const probes = registerProbe("test:backtest-null-moved-probe");
    const dir = await writeCorpus(fixtureFiles(TRAININGS_WITH_NULL_MOVED));

    const { results } = await runEval({
      corpusDir: dir,
      classifiers: ["test:backtest-null-moved-probe"],
      mode: "backtest",
    });

    // T0 (no moved_at) is present from the very first case: 2/3/4.
    expect(probes.map((p) => p.userMoved)).toEqual([2, 3, 4]);
    expect(results.map((r) => r.trainingSizeAtCase)).toEqual([2, 3, 4]);
    expect(
      errSpy.mock.calls
        .flat()
        .some((line) =>
          String(line).includes("1 training thread(s) without moved_at")
        )
    ).toBe(true);
  }, 60_000);

  it("rejects more than one named training set", async () => {
    registerProbe("test:backtest-err-probe");
    const dir = await writeCorpus(fixtureFiles());
    await expect(
      runEval({
        corpusDir: dir,
        classifiers: ["test:backtest-err-probe"],
        mode: "backtest",
        trainingSets: ["full", "other"],
      })
    ).rejects.toThrow(/exactly one training set/i);
  }, 60_000);

  it("errors when the default 'full' set is absent, naming available sets", async () => {
    registerProbe("test:backtest-missing-probe");
    const files = fixtureFiles();
    files["trainings/solo.yaml"] = TRAININGS_FULL.replace(
      "name: full",
      "name: solo"
    );
    delete files["trainings/full.yaml"];
    const dir = await writeCorpus(files);
    await expect(
      runEval({
        corpusDir: dir,
        classifiers: ["test:backtest-missing-probe"],
        mode: "backtest",
      })
    ).rejects.toThrow(/full.*solo|solo.*full/s);
  }, 60_000);
});
