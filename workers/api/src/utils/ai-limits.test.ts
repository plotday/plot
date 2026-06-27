import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import { checkAiLimit, INTERNAL_AI_CAP, isAiEnabled } from "./ai-limits";
import type { DB } from "../db-types";
import type { Bindings } from "../env";

// ---------------------------------------------------------------------------
// Kysely fake — used by isAiEnabled tests (two-table SELECT only)
// ---------------------------------------------------------------------------

function db(
  aiPreference: Record<string, unknown> | null,
  userSettings: Record<string, unknown> | null
): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      if (compiled.sql.includes("ai_preference")) {
        return { rows: aiPreference ? [aiPreference] : [] } as never;
      }
      if (compiled.sql.includes("user_settings")) {
        return { rows: userSettings ? [userSettings] : [] } as never;
      }
      throw new Error(`unexpected SQL: ${compiled.sql}`);
    },
    streamQuery: () => {
      throw new Error("not implemented");
    },
  };
  return new Kysely<DB>({
    dialect: {
      createAdapter: () => new PostgresAdapter(),
      createDriver: () => ({
        init: async () => {},
        acquireConnection: async () => connection,
        beginTransaction: async () => {},
        commitTransaction: async () => {},
        rollbackTransaction: async () => {},
        releaseConnection: async () => {},
        destroy: async () => {},
      }),
      createIntrospector: (d) => new PostgresIntrospector(d),
      createQueryCompiler: () => new PostgresQueryCompiler(),
    },
  });
}

// ---------------------------------------------------------------------------
// Mock UserAiUsage Durable Object
// ---------------------------------------------------------------------------

const mockCheck = vi.fn<[string, number], Promise<{ allowed: boolean; remaining: number }>>();

vi.mock("../state/user-ai-usage", () => ({
  UserAiUsage: {
    Get: () => ({ check: mockCheck }),
  },
}));

beforeEach(() => {
  mockCheck.mockReset();
});

// ---------------------------------------------------------------------------
// INTERNAL_AI_CAP — value assertions
// ---------------------------------------------------------------------------

describe("INTERNAL_AI_CAP", () => {
  it("is a high ceiling (>= 10 000) — abuse protection only, not a product limit", () => {
    expect(INTERNAL_AI_CAP.note_processing).toBeGreaterThanOrEqual(10_000);
  });
});

// ---------------------------------------------------------------------------
// checkAiLimit — uniform cap (no plan/team bypass)
// ---------------------------------------------------------------------------

describe("checkAiLimit (uniform cap)", () => {
  const fakeEnv = {} as Bindings;

  it("allows when under the internal cap", async () => {
    mockCheck.mockResolvedValue({ allowed: true, remaining: 9_999 });
    const result = await checkAiLimit(fakeEnv, db(null, null), "user-free", "note_processing");
    expect(result.allowed).toBe(true);
  });

  it("blocks when over the internal cap", async () => {
    mockCheck.mockResolvedValue({ allowed: false, remaining: 0 });
    const result = await checkAiLimit(fakeEnv, db(null, null), "user-free", "note_processing");
    expect(result.allowed).toBe(false);
    expect(result.remaining).toBe(0);
  });

  it("paid/team users are also subject to the cap — DB is never queried", async () => {
    // Previously isUserAiUnlimited returned true for paid/team users and they
    // bypassed the quota entirely. Now ALL users go through the DO check.
    mockCheck.mockResolvedValue({ allowed: true, remaining: 5_000 });

    // A DB that throws if queried — verifies the plan lookup was removed.
    const throwingDb = new Proxy({} as Kysely<DB>, {
      get() {
        throw new Error("DB should not be queried in checkAiLimit — plan bypass removed");
      },
    });

    // Should NOT throw even though the DB proxy throws on any access.
    const result = await checkAiLimit(fakeEnv, throwingDb, "paid-user-id", "note_processing");
    expect(result.allowed).toBe(true);
  });

  it("passes INTERNAL_AI_CAP value to the usage check", async () => {
    mockCheck.mockResolvedValue({ allowed: true, remaining: 1 });
    await checkAiLimit(fakeEnv, db(null, null), "user-id", "note_processing");
    expect(mockCheck).toHaveBeenCalledWith("note_processing", INTERNAL_AI_CAP.note_processing);
  });
});

// ---------------------------------------------------------------------------
// isAiEnabled — unchanged behaviour
// ---------------------------------------------------------------------------

describe("isAiEnabled", () => {
  it("is disabled when ai_preference.builtin_ai_disabled is true", async () => {
    expect(await isAiEnabled(db({ builtin_ai_disabled: true }, null), "u")).toBe(
      false
    );
  });

  it("is enabled when ai_preference exists with builtin_ai_disabled false", async () => {
    expect(
      await isAiEnabled(db({ builtin_ai_disabled: false }, null), "u")
    ).toBe(true);
  });

  it("ai_preference wins over the legacy user_settings flag", async () => {
    // Preference present (enabled) must override a stale legacy ai_enabled=false.
    expect(
      await isAiEnabled(
        db({ builtin_ai_disabled: false }, { ai_enabled: false }),
        "u"
      )
    ).toBe(true);
  });

  it("falls back to legacy user_settings.ai_enabled when no preference row exists", async () => {
    expect(await isAiEnabled(db(null, { ai_enabled: false }), "u")).toBe(false);
    expect(await isAiEnabled(db(null, { ai_enabled: true }), "u")).toBe(true);
  });

  it("defaults to enabled when neither row exists", async () => {
    expect(await isAiEnabled(db(null, null), "u")).toBe(true);
  });
});
