import { describe, expect, it } from "vitest";
import ts from "typescript";

import TwistEntrypoint from "./entrypoint";

describe("twist entrypoint MODULE template", () => {
  it("is syntactically valid ESM (no unescaped backticks / template typos)", () => {
    // The MODULE is a template literal consumed verbatim as the loader
    // worker's index.js. A raw backtick or syntax slip only surfaces at
    // connector deploy time ("Expected \";\" but found ..."), so parse it
    // here with the TypeScript parser and fail fast on any diagnostic.
    const source = ts.createSourceFile(
      "module.js",
      TwistEntrypoint.Module,
      ts.ScriptTarget.ES2022,
      /* setParentNodes */ false,
      ts.ScriptKind.JS
    );
    const diagnostics = (
      source as unknown as { parseDiagnostics: ts.Diagnostic[] }
    ).parseDiagnostics;

    expect(
      diagnostics.map((d) =>
        typeof d.messageText === "string"
          ? `${d.start}: ${d.messageText}`
          : `${d.start}: ${d.messageText.messageText}`
      )
    ).toEqual([]);
  });

  it("wraps built-in tools with the tool-call metrics instrumentation", () => {
    // Smoke-check the load-bearing pieces are present in the template.
    expect(TwistEntrypoint.Module).toContain("instrumentToolStub");
    expect(TwistEntrypoint.Module).toContain("reportToolMetricsToHost");
    expect(TwistEntrypoint.Module).toContain("TIMED_TOOL_METHODS");
  });
});
