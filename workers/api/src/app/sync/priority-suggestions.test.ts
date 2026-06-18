import { describe, expect, it } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import { runSuggestPriorities } from "./priority-suggestions";
import type { DB } from "../../db-types";
import type { Bindings } from "../../env";

// Fake DB that only answers the isAiEnabled() probes. Any other query means the
// opt-out gate failed to short-circuit, so we throw to fail loudly.
function db(builtinAiDisabled: boolean): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      if (compiled.sql.includes("ai_preference")) {
        return { rows: [{ builtin_ai_disabled: builtinAiDisabled }] } as never;
      }
      if (compiled.sql.includes("user_settings")) {
        return { rows: [] } as never;
      }
      throw new Error(`unexpected SQL (gate did not short-circuit): ${compiled.sql}`);
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

const ENV = {} as Bindings;

describe("runSuggestPriorities built-in AI opt-out", () => {
  it("returns an empty result without touching the LLM when AI is disabled", async () => {
    const result = await runSuggestPriorities(ENV, db(true), "u-1", {
      since: null,
    });
    expect(result).toEqual({
      existing_priorities: [],
      suggestions: [],
      sample_count: 0,
      sampled_thread_count: 0,
    });
  });
});
