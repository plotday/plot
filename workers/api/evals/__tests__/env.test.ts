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
  it("names every missing var", () => {
    expect(() => assertRequiredVars({ ANTHROPIC_API_KEY: "x" })).toThrow(
      /AI_GATEWAY_ACCOUNT_ID.*AI_GATEWAY_ID.*AI_GATEWAY_TOKEN/s
    );
  });
});

describe("buildEvalEnv", () => {
  const vars = {
    ANTHROPIC_API_KEY: "k",
    AI_GATEWAY_ACCOUNT_ID: "a",
    AI_GATEWAY_ID: "g",
    AI_GATEWAY_TOKEN: "t",
    POSTHOG_API_KEY: "MUST_NOT_LEAK",
  };

  it("includes only the generation vars plus the container stub", () => {
    const env = buildEvalEnv(vars, 12345);
    expect(env.ANTHROPIC_API_KEY).toBe("k");
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
