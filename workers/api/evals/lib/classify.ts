import type { GenerateAttemptEvent } from "../../src/twist/generator";
import type { BuildFailureClass, Classification } from "./types";

export function classifyBuildErrors(errors: string[]): BuildFailureClass {
  const joined = errors.join("\n");
  if (joined.includes("Failed to install dependencies")) {
    return "build_npm_install";
  }
  if (
    joined.includes("Container build request failed") ||
    joined.includes("Build failed with exception") ||
    joined.includes("Sandbox (Container) binding is not configured")
  ) {
    return "build_container_infra";
  }
  if (joined.includes("Type check failed")) {
    return "build_typecheck";
  }
  return "build_bundle";
}

/**
 * Map a generateTwist() rejection (plus collected telemetry events) to a
 * taxonomy class. Prefers structured evidence (error name, finishReason,
 * build_complete events); message matching is the fallback and lives ONLY
 * here. Unknown errors default to api_error — everything else in the LLM
 * path is explicitly recognized above it.
 */
export function classifyGenerationError(
  error: unknown,
  events: GenerateAttemptEvent[]
): Classification {
  const err = error instanceof Error ? error : new Error(String(error ?? "unknown"));
  const name = err.name ?? "";
  const message = err.message ?? "";
  const detail = message.slice(0, 500);

  if (name === "AI_NoObjectGeneratedError") {
    const finishReason = (err as { finishReason?: string }).finishReason;
    return {
      failureClass: finishReason === "length" ? "output_truncated" : "schema_mismatch",
      detail,
    };
  }
  if (message.includes("missing required 'index.ts'")) {
    return { failureClass: "schema_mismatch", detail };
  }
  if (message.startsWith("Failed to generate valid twist after")) {
    const lastFailedBuild = [...events]
      .reverse()
      .find(
        (e): e is Extract<GenerateAttemptEvent, { type: "build_complete" }> =>
          e.type === "build_complete" && !e.success
      );
    return {
      failureClass: "max_attempts_exhausted",
      finalBuildClass: classifyBuildErrors(lastFailedBuild?.errors ?? [message]),
      detail,
    };
  }
  if (message.includes("AI Gateway configuration is missing")) {
    return { failureClass: "infra", detail };
  }
  return { failureClass: "api_error", detail };
}
