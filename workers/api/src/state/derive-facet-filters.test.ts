import { describe, expect, it, vi } from "vitest";

// Capture the generateObject params so we can assert on the ai@7 instructions
// shape (see generator.test.ts for the reference pattern).
const generateObjectMock = vi.fn();
vi.mock("ai", () => ({
  generateObject: (...args: unknown[]) => generateObjectMock(...args),
}));

import { deriveFacetFilters } from "./derive-facet-filters";
import type { Bindings } from "../env";

describe("deriveFacetFilters", () => {
  it("returns null (fail-open) when the AI gateway is not configured", async () => {
    const env = {
      AI_GATEWAY_ACCOUNT_ID: "",
      AI_GATEWAY_ID: "",
      AI_GATEWAY_TOKEN: "",
      ANTHROPIC_API_KEY: "",
    } as unknown as Bindings;
    expect(await deriveFacetFilters(env, "Reading", "newsletters")).toBeNull();
  });

  it("sends the system prompt via `instructions` and only a user message in `messages`", async () => {
    generateObjectMock.mockReset();
    generateObjectMock.mockResolvedValueOnce({ object: {} });

    const env = {
      AI_GATEWAY_ACCOUNT_ID: "acct",
      AI_GATEWAY_ID: "gw",
      AI_GATEWAY_TOKEN: "token",
      GOOGLE_GENERATIVE_AI_API_KEY: "gkey",
    } as unknown as Bindings;

    const result = await deriveFacetFilters(env, "Reading", "newsletters");

    expect(result).toEqual({});
    expect(generateObjectMock).toHaveBeenCalledTimes(1);
    const call = generateObjectMock.mock.calls[0][0];
    // Gemini (the system model) needs no provider-specific caching options,
    // so instructions is a plain string — a `{role:"system"}` messages entry
    // here would make ai@7's generateObject throw before any network call.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("You configure classification filters");
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });
});
