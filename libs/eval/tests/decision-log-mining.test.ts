import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import pg from "pg";

import type { PgClient } from "../src/seeder/extract";
import {
  mineDecisionLog,
  minedCaseOverride,
  type MinedCase,
} from "../src/seeder/from-decision-log";

// ===========================================================================
// Fixture ids (distinct namespace; no other test uses d2…/ddd1…)
// ===========================================================================

const USER = "d2000000-0000-4000-8000-000000000001";
const OTHER_USER = "d2000000-0000-4000-8000-000000000002";
const P_A = "d2000000-0000-4000-8000-000000000010";
const P_B = "d2000000-0000-4000-8000-000000000011";
const P_C = "d2000000-0000-4000-8000-000000000012";
const T1 = "ddd10001-0000-4000-8000-000000000100";
const T2 = "ddd10002-0000-4000-8000-000000000101";
const T3 = "ddd10003-0000-4000-8000-000000000102";
const T4 = "ddd10004-0000-4000-8000-000000000103";
const T5 = "ddd10005-0000-4000-8000-000000000104";
const T6 = "ddd10006-0000-4000-8000-000000000105";

const TS_CLASSIFIER = "ts:hybrid-llm:production@deadbeef01";
const SQL_CLASSIFIER = "sql:classify_thread_for_user";

async function insertDecision(
  client: PgClient,
  d: {
    threadId: string;
    userId?: string;
    priorityId: string | null;
    stage: string;
    classifier?: string;
    createdAt: string;
  }
): Promise<void> {
  await client.query(
    `INSERT INTO public.classification_decision
       (thread_id, user_id, priority_id, stage, classifier, created_at)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [
      d.threadId,
      d.userId ?? USER,
      d.priorityId,
      d.stage,
      d.classifier ?? (d.stage === "user_move" ? "user" : TS_CLASSIFIER),
      d.createdAt,
    ]
  );
}

// ===========================================================================
// DB-gated mining tests (transaction + ROLLBACK; the table has no FKs)
// ===========================================================================

describe.runIf(!!process.env.DATABASE_URL)("mineDecisionLog (db)", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: process.env.DATABASE_URL });
    await client.connect();
  });

  afterAll(async () => {
    await client.end();
  });

  beforeEach(async () => {
    await client.query("BEGIN");
  });

  afterEach(async () => {
    await client.query("ROLLBACK");
  });

  it("mines auto(scoring→A) then user_move(B); scoped to the user", async () => {
    await insertDecision(client, {
      threadId: T1,
      priorityId: P_A,
      stage: "scoring",
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T1,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });
    // Another user's qualifying pair must NOT leak into USER's mining.
    await insertDecision(client, {
      threadId: T2,
      userId: OTHER_USER,
      priorityId: P_A,
      stage: "scoring",
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T2,
      userId: OTHER_USER,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });

    const { tableMissing, mined } = await mineDecisionLog(client, USER);
    expect(tableMissing).toBe(false);
    expect(mined).toEqual([
      {
        threadId: T1,
        autoPriorityId: P_A,
        autoStage: "scoring",
        autoClassifier: TS_CLASSIFIER,
        decidedAt: "2026-05-01T10:00:00.000Z",
        movedTo: P_B,
      },
    ]);
  });

  it("mines stage 'none' (NULL priority) → autoPriorityId null", async () => {
    await insertDecision(client, {
      threadId: T2,
      priorityId: null,
      stage: "none",
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T2,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });

    const { mined } = await mineDecisionLog(client, USER);
    expect(mined).toHaveLength(1);
    expect(mined[0]!.autoPriorityId).toBeNull();
    expect(mined[0]!.autoStage).toBe("none");
    expect(mined[0]!.movedTo).toBe(P_B);
  });

  it("does not mine a user_move to the SAME priority as the auto decision", async () => {
    await insertDecision(client, {
      threadId: T3,
      priorityId: P_A,
      stage: "scoring",
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T3,
      priorityId: P_A,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });

    const { mined } = await mineDecisionLog(client, USER);
    expect(mined).toEqual([]);
  });

  it("does not mine a user_move with no EARLIER auto decision", async () => {
    await insertDecision(client, {
      threadId: T4,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-01T10:00:00Z",
    });
    // An auto decision logged AFTER the move does not count.
    await insertDecision(client, {
      threadId: T4,
      priorityId: P_A,
      stage: "scoring",
      createdAt: "2026-05-02T10:00:00Z",
    });

    const { mined } = await mineDecisionLog(client, USER);
    expect(mined).toEqual([]);
  });

  it("two user_moves (A→B then B→C) → ONE case: movedTo = C, auto before that move", async () => {
    await insertDecision(client, {
      threadId: T5,
      priorityId: P_A,
      stage: "scoring",
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T5,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T5,
      priorityId: P_C,
      stage: "user_move",
      createdAt: "2026-05-03T10:00:00Z",
    });

    const { mined } = await mineDecisionLog(client, USER);
    expect(mined).toEqual([
      {
        threadId: T5,
        autoPriorityId: P_A,
        autoStage: "scoring",
        autoClassifier: TS_CLASSIFIER,
        decidedAt: "2026-05-01T10:00:00.000Z",
        movedTo: P_C,
      },
    ]);
  });

  it("mines sql:applied auto rows with their stage (the asymmetry bucket)", async () => {
    await insertDecision(client, {
      threadId: T6,
      priorityId: P_A,
      stage: "sql:applied",
      classifier: SQL_CLASSIFIER,
      createdAt: "2026-05-01T10:00:00Z",
    });
    await insertDecision(client, {
      threadId: T6,
      priorityId: P_B,
      stage: "user_move",
      createdAt: "2026-05-02T10:00:00Z",
    });

    const { mined } = await mineDecisionLog(client, USER);
    expect(mined).toHaveLength(1);
    expect(mined[0]!.autoStage).toBe("sql:applied");
    expect(mined[0]!.autoClassifier).toBe(SQL_CLASSIFIER);
  });

  it("missing table → { tableMissing: true, mined: [] } (DROP rolled back)", async () => {
    await client.query("DROP TABLE public.classification_decision");
    const result = await mineDecisionLog(client, USER);
    expect(result).toEqual({ tableMissing: true, mined: [] });
  });
});

// ===========================================================================
// Pure label-building tests (no DB)
// ===========================================================================

describe("minedCaseOverride", () => {
  const base: MinedCase = {
    threadId: T1,
    autoPriorityId: P_A,
    autoStage: "scoring",
    autoClassifier: TS_CLASSIFIER,
    decidedAt: "2026-05-01T10:00:00.000Z",
    movedTo: P_B,
  };
  const RECORDED = "2026-06-11T00:00:00.000Z";

  it("maps a mined case to gold/expected labels, tags and as_of", () => {
    const o = minedCaseOverride({
      mined: base,
      goldSlug: "personal",
      expectedSlug: "inbox",
      recordedAtIso: RECORDED,
    });
    expect(o.tags).toEqual(["decision-log"]);
    expect(o.asOf).toBe("2026-05-01T10:00:00.000Z");
    expect(o.labels).toEqual({
      gold: "personal",
      gold_rationale:
        "mined from classification_decision: user moved off scoring decision",
      gold_source: "human",
      expected: "inbox",
      expected_stage: "scoring",
      expected_recorded_at: RECORDED,
    });
    // High-confidence stages carry no asymmetry note.
    expect(o.notes).toBe("");
    expect(o.description).toContain("classification_decision");
  });

  it("stage 'none' → expected null + the low-confidence asymmetry note", () => {
    const o = minedCaseOverride({
      mined: { ...base, autoStage: "none", autoPriorityId: null },
      goldSlug: "personal",
      expectedSlug: null,
      recordedAtIso: RECORDED,
    });
    expect(o.labels.expected).toBeNull();
    expect(o.labels.expected_stage).toBe("none");
    expect(o.notes).toContain("stage 'none'");
    expect(o.notes).toContain("NULL priority");
    expect(o.notes).toContain("sql:applied");
    expect(o.notes).toContain("low-confidence");
  });

  it("stage 'sql:applied' → same asymmetry note (root resolved, same bucket)", () => {
    const o = minedCaseOverride({
      mined: {
        ...base,
        autoStage: "sql:applied",
        autoClassifier: SQL_CLASSIFIER,
      },
      goldSlug: "personal",
      expectedSlug: "everything",
      recordedAtIso: RECORDED,
    });
    expect(o.labels.expected).toBe("everything");
    expect(o.labels.expected_stage).toBe("sql:applied");
    expect(o.notes).toContain("sql:applied");
    expect(o.notes).toContain("low-confidence");
  });

  it("other cascade stages (llm_tiebreaker) carry no note", () => {
    const o = minedCaseOverride({
      mined: { ...base, autoStage: "llm_tiebreaker" },
      goldSlug: "personal",
      expectedSlug: "inbox",
      recordedAtIso: RECORDED,
    });
    expect(o.notes).toBe("");
    expect(o.labels.gold_rationale).toBe(
      "mined from classification_decision: user moved off llm_tiebreaker decision"
    );
  });
});
