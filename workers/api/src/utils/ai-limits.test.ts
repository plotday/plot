import { describe, expect, it } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import { isAiEnabled } from "./ai-limits";
import type { DB } from "../db-types";

// Minimal Kysely fake: each query is answered by a per-table responder keyed on
// the compiled SQL. isAiEnabled issues exactly two SELECTs (ai_preference and
// user_settings) in parallel, so we route by table name.
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
