import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import { assertRequiredVars, buildEvalEnv, loadDevVars } from "../lib/env";

describe("loadDevVars", () => {
  it("parses assignments, quotes, and comments", () => {
    const dir = mkdtempSync(join(tmpdir(), "eval-env-"));
    const file = join(dir, ".dev.vars");
    writeFileSync(
      file,
      [
        "# comment",
        "PLAIN=value",
        'QUOTED="with spaces"',
        "SINGLE='single'",
        "",
        "WITH_EQ=a=b",
      ].join("\n")
    );
    expect(loadDevVars(file)).toEqual({
      PLAIN: "value",
      QUOTED: "with spaces",
      SINGLE: "single",
      WITH_EQ: "a=b",
    });
  });
});

describe("assertRequiredVars", () => {
  it("names every missing var for a gemini model", () => {
    expect(() =>
      assertRequiredVars({ GOOGLE_GENERATIVE_AI_API_KEY: "g" }, "gemini-3-pro-preview")
    ).toThrow(/AI_GATEWAY_ACCOUNT_ID.*AI_GATEWAY_ID.*AI_GATEWAY_TOKEN/s);
  });

  it("does not require ANTHROPIC_API_KEY for gemini models", () => {
    expect(() =>
      assertRequiredVars(
        {
          GOOGLE_GENERATIVE_AI_API_KEY: "g",
          AI_GATEWAY_ACCOUNT_ID: "a",
          AI_GATEWAY_ID: "i",
          AI_GATEWAY_TOKEN: "t",
        },
        "gemini-3-pro-preview"
      )
    ).not.toThrow();
  });

  it("requires ANTHROPIC_API_KEY for claude models", () => {
    expect(() =>
      assertRequiredVars(
        {
          GOOGLE_GENERATIVE_AI_API_KEY: "g",
          AI_GATEWAY_ACCOUNT_ID: "a",
          AI_GATEWAY_ID: "i",
          AI_GATEWAY_TOKEN: "t",
        },
        "claude-sonnet-4-6"
      )
    ).toThrow(/ANTHROPIC_API_KEY/);
  });
});

describe("buildEvalEnv", () => {
  const vars = {
    ANTHROPIC_API_KEY: "k",
    GOOGLE_GENERATIVE_AI_API_KEY: "g",
    AI_GATEWAY_ACCOUNT_ID: "a",
    AI_GATEWAY_ID: "g",
    AI_GATEWAY_TOKEN: "t",
    POSTHOG_API_KEY: "MUST_NOT_LEAK",
  };

  it("includes only the generation vars plus the container stub", () => {
    const env = buildEvalEnv(vars, 12345);
    expect(env.ANTHROPIC_API_KEY).toBe("k");
    expect(env.GOOGLE_GENERATIVE_AI_API_KEY).toBe("g");
    expect(env.POSTHOG_API_KEY).toBeUndefined();
    expect(env.TWIST_BUILDER).toBeDefined();
  });

  it("stub routes fetches to the local container port", () => {
    const env = buildEvalEnv(vars, 12345) as {
      TWIST_BUILDER: {
        idFromName: (n: string) => unknown;
        get: (id: unknown) => { fetch: (...args: unknown[]) => unknown };
      };
    };
    const stub = env.TWIST_BUILDER.get(env.TWIST_BUILDER.idFromName("builder"));
    expect(typeof stub.fetch).toBe("function");
  });
});
