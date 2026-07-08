import { describe, expect, it, vi } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

// Capture the generateObject params so we can assert on the ai@7 instructions
// shape (see generator.test.ts for the reference pattern).
const generateObjectMock = vi.fn();
vi.mock("ai", () => ({
  generateObject: (...args: unknown[]) => generateObjectMock(...args),
}));

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

// Full fake DB that also answers the data-fetch queries runSuggestPriorities
// issues once past the opt-out gate: priorities, connections, channels, and
// sampled thread titles. One connection row is enough to clear the
// "connections.length === 0 && samples.length === 0" early return so the
// LLM call is actually reached.
function dbWithData(): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      if (compiled.sql.includes("ai_preference")) {
        return { rows: [{ builtin_ai_disabled: false }] } as never;
      }
      if (compiled.sql.includes("user_settings")) {
        return { rows: [] } as never;
      }
      if (compiled.sql.includes("public.priority p")) {
        return { rows: [] } as never;
      }
      if (compiled.sql.includes("tw.is_source = TRUE")) {
        return {
          rows: [
            {
              twist_instance_id: "ti-1",
              connector: "gmail",
              connector_description: "Email",
              account_label: "kris@acme.com",
              channel_count: 1,
            },
          ],
        } as never;
      }
      if (compiled.sql.includes("c.enabled = TRUE")) {
        return { rows: [] } as never;
      }
      if (compiled.sql.includes("public.link l")) {
        return { rows: [] } as never;
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

const ENV_WITH_GATEWAY = {
  AI_GATEWAY_ACCOUNT_ID: "acct",
  AI_GATEWAY_ID: "gw",
  AI_GATEWAY_TOKEN: "token",
  GOOGLE_GENERATIVE_AI_API_KEY: "gkey",
} as unknown as Bindings;

describe("runSuggestPriorities LLM call shape", () => {
  it("sends the system prompt via `instructions` and only a user message in `messages`", async () => {
    generateObjectMock.mockReset();
    generateObjectMock.mockResolvedValueOnce({ object: { suggestions: [] } });

    const result = await runSuggestPriorities(
      ENV_WITH_GATEWAY,
      dbWithData(),
      "u-1",
      { since: null }
    );

    expect(result.error).toBeUndefined();
    expect(generateObjectMock).toHaveBeenCalledTimes(1);
    const call = generateObjectMock.mock.calls[0][0];
    // Gemini (the system model) needs no provider-specific caching options,
    // so instructions is a plain string — a `{role:"system"}` messages entry
    // here would make ai@7's generateObject throw before any network call.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("You suggest a starter set of Plot priorities");
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });
});
