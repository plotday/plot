import { describe, it, expect, vi, beforeEach } from "vitest";

import { generateTwist, type GenerateAttemptEvent } from "./generator";

// Stub the twister docs exports — they're huge static strings and we don't
// need their real content for unit tests.
vi.mock("@plotday/twister/creator-docs", () => ({
  getBuilderDocumentation: () => "<SDK_DOCS>",
}));
vi.mock("@plotday/twister/twist-guide", () => ({
  TWIST_GUIDE: "<TWIST_GUIDE>",
}));

// Control what the builder returns per-attempt.
const buildTwistMock = vi.fn();
vi.mock("./builder", () => ({
  buildTwist: (...args: unknown[]) => buildTwistMock(...args),
}));

// Capture the generateObject params so we can assert on the prompt shape,
// caching hints, and model id.
const generateObjectMock = vi.fn();
vi.mock("ai", () => ({
  generateObject: (...args: unknown[]) => generateObjectMock(...args),
}));

// Anthropic provider factory — the real one hits the network on construction,
// so we swap it for a callable sentinel. modelIdMock records which model id
// the generator requested.
const anthropicModelSentinel = { __sentinel: "model" };
const createAnthropicMock = vi.fn();
const modelIdMock = vi.fn();
vi.mock("@ai-sdk/anthropic", () => ({
  createAnthropic: (opts?: unknown) => {
    createAnthropicMock(opts);
    return (modelId: string) => {
      modelIdMock(modelId);
      return anthropicModelSentinel;
    };
  },
}));

// Google provider factory — same sentinel pattern as the Anthropic mock.
const googleModelSentinel = { __sentinel: "google-model" };
const createGoogleMock = vi.fn();
const googleModelIdMock = vi.fn();
vi.mock("@ai-sdk/google", () => ({
  createGoogleGenerativeAI: (opts?: unknown) => {
    createGoogleMock(opts);
    return (modelId: string) => {
      googleModelIdMock(modelId);
      return googleModelSentinel;
    };
  },
}));

// What the MODEL now returns (array-shaped, Gemini-compatible); generateTwist
// maps it back into the Record-shaped TwistSource that all downstream
// consumers (builder, container, harness checks) still expect unchanged.
const validGenerated = {
  displayName: "Sample Twist",
  dependencies: [] as Array<{ name: string; version: string }>,
  files: [
    { path: "index.ts", content: "export default class SampleTwist {}" },
  ],
};

function makeEnv(overrides: Record<string, string | undefined> = {}) {
  return {
    AI_GATEWAY_ACCOUNT_ID: "acct",
    AI_GATEWAY_ID: "gw",
    AI_GATEWAY_TOKEN: "token",
    ANTHROPIC_API_KEY: "key",
    GOOGLE_GENERATIVE_AI_API_KEY: "gkey",
    TWIST_BUILDER: {},
    ...overrides,
  } as any;
}

// File-scope (not nested in a single describe) so every test in every
// describe below gets a fresh, valid default mock — several tests further
// down rely on this ambient default rather than setting their own, and a
// scoped-to-one-describe reset would let state leak across sibling describes
// depending on declaration order.
beforeEach(() => {
  buildTwistMock.mockReset();
  generateObjectMock.mockReset();
  createAnthropicMock.mockClear();
  modelIdMock.mockClear();
  createGoogleMock.mockClear();
  googleModelIdMock.mockClear();
  // Default: model returns a valid source.
  generateObjectMock.mockResolvedValue({ object: { ...validGenerated } });
});

describe("generateTwist", () => {
  it("throws when AI Gateway config is missing", async () => {
    await expect(
      generateTwist({
        spec: "build something",
        env: makeEnv({ AI_GATEWAY_ACCOUNT_ID: undefined }),
      })
    ).rejects.toThrow(/AI Gateway configuration is missing/);
  });

  it("returns the source on first-attempt build success", async () => {
    buildTwistMock.mockResolvedValueOnce({
      success: true,
      module: "ok",
    });

    const onProgress = vi.fn();
    const result = await generateTwist({
      spec: "make a tiny twist",
      env: makeEnv(),
      onProgress,
    });

    expect(result.files["index.ts"]).toBeDefined();
    expect(result.dependencies["@plotday/twister"]).toBe("latest");
    expect(generateObjectMock).toHaveBeenCalledTimes(1);
    expect(buildTwistMock).toHaveBeenCalledTimes(1);
    expect(onProgress).toHaveBeenCalledWith("Generating twist code");
  });

  it("defaults to Gemini with a plain-string system prompt via instructions", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "anything", env: makeEnv() });

    expect(createGoogleMock).toHaveBeenCalledTimes(1);
    expect(createAnthropicMock).not.toHaveBeenCalled();
    // Routed through the AI Gateway's Google AI Studio endpoint.
    const providerOpts = createGoogleMock.mock.calls[0][0] as { baseURL: string };
    expect(providerOpts.baseURL).toContain("/google-ai-studio/v1beta");

    const call = generateObjectMock.mock.calls[0][0];
    expect(call.maxOutputTokens).toBeGreaterThanOrEqual(16_000);
    // Gemini 2.5+/3 caches large repeated prefixes implicitly — no provider
    // options needed, so instructions is a plain string.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("<SDK_DOCS>");
    expect(call.instructions).toContain("<TWIST_GUIDE>");
    // messages must contain ONLY the user message — a system entry here
    // would make ai@7's generateObject throw before any network call.
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });

  it("keeps the anthropic cacheControl instructions shape for claude models", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({
      spec: "anything",
      env: makeEnv(),
      model: "claude-sonnet-4-6",
    });

    expect(createAnthropicMock).toHaveBeenCalledTimes(1);
    expect(createGoogleMock).not.toHaveBeenCalled();

    const call = generateObjectMock.mock.calls[0][0];
    // ai@7 forbids system-role entries in `messages` — the system prompt goes
    // through the `instructions` option as a SystemModelMessage, which is the
    // only shape that still carries the anthropic cacheControl marker.
    expect(call.instructions).toEqual(
      expect.objectContaining({
        role: "system",
        providerOptions: {
          anthropic: { cacheControl: { type: "ephemeral" } },
        },
      })
    );
    expect(call.instructions.content).toContain("<SDK_DOCS>");
    expect(call.instructions.content).toContain("<TWIST_GUIDE>");
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");
  });

  it("sends the spec on the first attempt and a correction prompt on retries", async () => {
    buildTwistMock
      .mockResolvedValueOnce({ success: false, errors: ["boom"] })
      .mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "SPEC_MARKER_123", env: makeEnv() });

    expect(generateObjectMock).toHaveBeenCalledTimes(2);

    const firstUser = generateObjectMock.mock.calls[0][0].messages.find(
      (m: any) => m.role === "user"
    );
    expect(firstUser.content).toContain("SPEC_MARKER_123");

    const retryUser = generateObjectMock.mock.calls[1][0].messages.find(
      (m: any) => m.role === "user"
    );
    expect(retryUser.content).toContain("previous attempt");
    expect(retryUser.content).toContain("boom");
  });

  it("retries up to 3 times and then throws with the final errors", async () => {
    buildTwistMock.mockResolvedValue({ success: false, errors: ["still bad"] });

    await expect(
      generateTwist({ spec: "x", env: makeEnv() })
    ).rejects.toThrow(/Failed to generate valid twist after 3 attempts/);

    expect(generateObjectMock).toHaveBeenCalledTimes(3);
    expect(buildTwistMock).toHaveBeenCalledTimes(3);
  });
});

describe("generateTwist telemetry hooks", () => {
  it("uses the default model when no override is given", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv() });
    expect(googleModelIdMock).toHaveBeenCalledWith("gemini-3.1-pro-preview");
    expect(modelIdMock).not.toHaveBeenCalled();
  });

  it("honors the model override", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv(), model: "claude-opus-4-8" });
    expect(modelIdMock).toHaveBeenCalledWith("claude-opus-4-8");
  });

  it("emits attempt_start, llm_complete, build_complete per attempt, in order", async () => {
    buildTwistMock
      .mockResolvedValueOnce({ success: false, errors: ["Build failed:\nboom"] })
      .mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    expect(events.map((e) => `${e.type}:${e.attempt}`)).toEqual([
      "attempt_start:1",
      "llm_complete:1",
      "build_complete:1",
      "attempt_start:2",
      "llm_complete:2",
      "build_complete:2",
    ]);
    const firstBuild = events[2];
    if (firstBuild.type !== "build_complete") throw new Error("expected build_complete");
    expect(firstBuild.success).toBe(false);
    expect(firstBuild.errors).toEqual(["Build failed:\nboom"]);
    const secondBuild = events[5];
    if (secondBuild.type !== "build_complete") throw new Error("expected build_complete");
    expect(secondBuild.success).toBe(true);
    expect(secondBuild.errors).toBeUndefined();
  });

  it("passes token usage through to llm_complete", async () => {
    generateObjectMock.mockResolvedValue({
      object: { ...validGenerated },
      usage: { inputTokens: 100, outputTokens: 42 },
      providerMetadata: {
        anthropic: { cacheReadInputTokens: 70, cacheCreationInputTokens: 30 },
      },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    const llm = events.find((e) => e.type === "llm_complete");
    if (!llm || llm.type !== "llm_complete") throw new Error("expected llm_complete");
    expect(llm.usage).toEqual({
      inputTokens: 100,
      outputTokens: 42,
      cacheReadInputTokens: 70,
      cacheCreationInputTokens: 30,
    });
  });

  it("a throwing onEvent listener does not break generation", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const source = await generateTwist({
      spec: "hello",
      env: makeEnv(),
      onEvent: () => {
        throw new Error("listener bug");
      },
    });
    expect(source.files["index.ts"]).toBeTruthy();
  });
});

describe("generateTwist provider routing", () => {
  it("rejects an unsupported model id", async () => {
    await expect(
      generateTwist({ spec: "hello", env: makeEnv(), model: "gpt-4o" })
    ).rejects.toThrow(/Unsupported generation model: gpt-4o/);
  });

  it("rejects a gemini model when GOOGLE_GENERATIVE_AI_API_KEY is missing", async () => {
    await expect(
      generateTwist({
        spec: "hello",
        env: makeEnv({ GOOGLE_GENERATIVE_AI_API_KEY: undefined }),
      })
    ).rejects.toThrow(/GOOGLE_GENERATIVE_AI_API_KEY is missing/);
  });

  it("rejects a claude model when ANTHROPIC_API_KEY is missing", async () => {
    await expect(
      generateTwist({
        spec: "hello",
        env: makeEnv({ ANTHROPIC_API_KEY: undefined }),
        model: "claude-sonnet-4-6",
      })
    ).rejects.toThrow(/ANTHROPIC_API_KEY is missing/);
  });

  it("maps google cached-content metadata into llm_complete usage", async () => {
    generateObjectMock.mockResolvedValue({
      object: { ...validGenerated },
      usage: { inputTokens: 100, outputTokens: 42 },
      providerMetadata: { google: { cachedContentTokenCount: 55 } },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    const llm = events.find((e) => e.type === "llm_complete");
    if (!llm || llm.type !== "llm_complete") throw new Error("expected llm_complete");
    expect(llm.usage).toEqual({
      inputTokens: 100,
      outputTokens: 42,
      cacheReadInputTokens: 55,
      cacheCreationInputTokens: undefined,
    });
  });
});

describe("generated-shape mapping", () => {
  it("maps files and dependencies arrays into TwistSource records", async () => {
    generateObjectMock.mockResolvedValue({
      object: {
        displayName: "Mapper",
        files: [
          { path: "index.ts", content: "export default class M {}" },
          { path: "lib/util.ts", content: "export const x = 1;" },
        ],
        dependencies: [{ name: "zod", version: "^4.0.0" }],
      },
    });
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const source = await generateTwist({ spec: "hello", env: makeEnv() });
    expect(source.files["index.ts"]).toContain("class M");
    expect(source.files["lib/util.ts"]).toBe("export const x = 1;");
    expect(source.dependencies).toEqual({
      zod: "^4.0.0",
      "@plotday/twister": "latest",
    });
  });

  it("still rejects when no files entry has path index.ts", async () => {
    generateObjectMock.mockResolvedValue({
      object: {
        displayName: "NoEntry",
        files: [{ path: "main.ts", content: "export {}" }],
        dependencies: [],
      },
    });
    await expect(
      generateTwist({ spec: "hello", env: makeEnv() })
    ).rejects.toThrow(/missing required 'index.ts'/);
  });
});

describe("gateway cache bypass", () => {
  it("adds cf-aig-skip-cache when skipGatewayCache is set", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv(), skipGatewayCache: true });
    const opts = createGoogleMock.mock.calls[0][0] as {
      headers: Record<string, string>;
    };
    expect(opts.headers["cf-aig-skip-cache"]).toBe("true");
  });

  it("omits cf-aig-skip-cache by default", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    await generateTwist({ spec: "hello", env: makeEnv() });
    const opts = createGoogleMock.mock.calls[0][0] as {
      headers: Record<string, string>;
    };
    expect(opts.headers["cf-aig-skip-cache"]).toBeUndefined();
  });
});
