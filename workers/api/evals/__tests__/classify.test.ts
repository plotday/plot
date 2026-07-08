import { describe, it, expect } from "vitest";

import { classifyBuildErrors, classifyGenerationError } from "../lib/classify";
import type { GenerateAttemptEvent } from "../../src/twist/generator";

function namedError(name: string, message: string, extra: Record<string, unknown> = {}) {
  const err = new Error(message);
  err.name = name;
  Object.assign(err, extra);
  return err;
}

describe("classifyBuildErrors", () => {
  it("detects npm install failures", () => {
    expect(
      classifyBuildErrors(["Failed to install dependencies:\nnpm ERR! 404"])
    ).toBe("build_npm_install");
  });

  it("detects container infra failures", () => {
    expect(
      classifyBuildErrors(["Container build request failed with status 500:\nboom"])
    ).toBe("build_container_infra");
    expect(classifyBuildErrors(["Build failed with exception: fetch failed"])).toBe(
      "build_container_infra"
    );
  });

  it("defaults to bundle failures", () => {
    expect(classifyBuildErrors(["Build failed:\nesbuild: Expected ';'"])).toBe(
      "build_bundle"
    );
  });
});

describe("classifyGenerationError", () => {
  it("classifies truncation", () => {
    const c = classifyGenerationError(
      namedError("AI_NoObjectGeneratedError", "could not parse", {
        finishReason: "length",
      }),
      []
    );
    expect(c.failureClass).toBe("output_truncated");
  });

  it("classifies schema mismatches", () => {
    const c = classifyGenerationError(
      namedError("AI_NoObjectGeneratedError", "schema validation failed", {
        finishReason: "stop",
      }),
      []
    );
    expect(c.failureClass).toBe("schema_mismatch");
  });

  it("classifies a missing index.ts as schema mismatch", () => {
    const c = classifyGenerationError(
      new Error("Generated connector is missing required 'index.ts' file"),
      []
    );
    expect(c.failureClass).toBe("schema_mismatch");
  });

  it("classifies exhausted retries and refines with the final build error", () => {
    const events: GenerateAttemptEvent[] = [
      { type: "attempt_start", attempt: 3 },
      { type: "llm_complete", attempt: 3, durationMs: 1 },
      {
        type: "build_complete",
        attempt: 3,
        durationMs: 1,
        success: false,
        errors: ["Failed to install dependencies:\nnpm ERR! 404 left-pad"],
      },
    ];
    const c = classifyGenerationError(
      new Error("Failed to generate valid twist after 3 attempts. Final errors:\n..."),
      events
    );
    expect(c.failureClass).toBe("max_attempts_exhausted");
    expect(c.finalBuildClass).toBe("build_npm_install");
  });

  it("classifies API call errors", () => {
    const c = classifyGenerationError(
      namedError("AI_APICallError", "overloaded", { statusCode: 529 }),
      []
    );
    expect(c.failureClass).toBe("api_error");
  });

  it("classifies missing gateway config as infra", () => {
    const c = classifyGenerationError(
      new Error("AI Gateway configuration is missing"),
      []
    );
    expect(c.failureClass).toBe("infra");
  });

  it("truncates detail to 500 chars and falls back to api_error", () => {
    const c = classifyGenerationError(new Error("x".repeat(2000)), []);
    expect(c.failureClass).toBe("api_error");
    expect(c.detail.length).toBe(500);
  });
});
