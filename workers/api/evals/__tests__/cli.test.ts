import { describe, it, expect } from "vitest";

import { parseCliArgs } from "../lib/cli";

describe("parseCliArgs", () => {
  it("returns defaults with no args", () => {
    expect(parseCliArgs([])).toEqual({
      only: null,
      model: null,
      runs: 1,
      concurrency: 3,
      label: null,
      compare: null,
      keepOutput: false,
      list: false,
    });
  });

  it("parses all flags and strips the pnpm-forwarded double dash", () => {
    const opts = parseCliArgs([
      "--",
      "--only",
      "hello-thread,webhook",
      "--model",
      "claude-opus-4-8",
      "--runs",
      "2",
      "--concurrency",
      "1",
      "--label",
      "baseline",
      "--compare",
      "results/x.json",
      "--keep-output",
      "--list",
    ]);
    expect(opts).toEqual({
      only: "hello-thread,webhook",
      model: "claude-opus-4-8",
      runs: 2,
      concurrency: 1,
      label: "baseline",
      compare: "results/x.json",
      keepOutput: true,
      list: true,
    });
  });

  it("rejects non-positive integers", () => {
    expect(() => parseCliArgs(["--runs", "0"])).toThrow(/positive integer/);
    expect(() => parseCliArgs(["--concurrency", "nope"])).toThrow(/positive integer/);
  });
});
