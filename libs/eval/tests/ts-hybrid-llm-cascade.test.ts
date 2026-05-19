import { describe, expect, it } from "vitest";
import { resolve } from "node:path";

import { runEval } from "../src/runner/run";
import { makeHybridLlmClassifier , DEFAULTS_LLM } from "@plotday/classifier";
import { registerVariant } from "../src/classifiers/registry";
import type { LLMClient } from "@plotday/classifier";

const SYNTHETIC_TINY_DIR = resolve(__dirname, "..", "corpora", "synthetic-tiny");

function stubLlm(): LLMClient {
  return {
    id: "stub:always-first",
    async classify(inputs) {
      return {
        priorityId: inputs.allowedPriorityIds[0] ?? null,
        rationale: "stub",
      };
    },
  };
}

describe.runIf(!!process.env.DATABASE_URL)("ts:hybrid-llm cascade", () => {
  it("does NOT call the LLM when scoring is confident on synthetic-tiny", async () => {
    const stub = stubLlm();
    registerVariant(
      "test:hybrid-llm:stub",
      makeHybridLlmClassifier("test:hybrid-llm:stub", {
        params: DEFAULTS_LLM,
        llmClientFor: () => stub,
      })
    );

    const { results } = await runEval({
      corpusDir: SYNTHETIC_TINY_DIR,
      classifiers: ["test:hybrid-llm:stub"],
      trainingSets: ["full"],
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));
    // priority_prefix (a hard topic signal) still fires deterministically.
    expect(byCase.get("001-priority-prefix")?.stage).toBe("priority_prefix");
    expect(byCase.get("001-priority-prefix")?.llmCalls).toBe(0);
    // The topic-shortcircuit case has only one same-topic training thread
    // on synthetic-tiny, which now trips the single-sample-fragility
    // ambiguity rule and escalates to the LLM. The stub LLM picks the
    // first allowed priority — same as topicShortCircuit would have.
    expect(byCase.get("003-topic-shortcircuit")?.stage).toBe(
      "llm_topic_ambiguity"
    );
  }, 60_000);
});
