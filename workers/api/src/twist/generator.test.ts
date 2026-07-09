import { describe, it, expect, vi, beforeEach } from "vitest";

import { generateTwist, type GenerateAttemptEvent } from "./generator";

function namedError(name: string, message: string, extra: Record<string, unknown> = {}) {
  const err = new Error(message);
  err.name = name;
  Object.assign(err, extra);
  return err;
}

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

// Capture streamText params and control its result. streamText returns its
// result object SYNCHRONOUSLY (promises/streams inside), so the mock does too.
const streamTextMock = vi.fn();
vi.mock("ai", () => ({
  streamText: (...args: unknown[]) => streamTextMock(...args),
  Output: {
    object: (opts: unknown) => ({ __outputSpec: opts }),
  },
}));

// Build a fake streamText result. `partials` drives partialOutputStream;
// `error` makes the stream throw mid-iteration and the output promise reject.
function fakeStream(
  object: unknown,
  opts: {
    usage?: unknown;
    providerMetadata?: unknown;
    partials?: unknown[];
    error?: Error;
    finishReason?: string;
  } = {}
) {
  const output = opts.error
    ? Promise.reject(opts.error)
    : Promise.resolve(object);
  output.catch(() => {}); // avoid unhandled rejection when the stream throws first
  return {
    partialOutputStream: (async function* () {
      for (const p of opts.partials ?? [object]) yield p;
      if (opts.error) throw opts.error;
    })(),
    output,
    usage: Promise.resolve(opts.usage ?? {}),
    finalStep: Promise.resolve({ providerMetadata: opts.providerMetadata }),
    finishReason: Promise.resolve(opts.finishReason ?? (opts.error ? "error" : "stop")),
  };
}

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
  streamTextMock.mockReset();
  createAnthropicMock.mockClear();
  modelIdMock.mockClear();
  createGoogleMock.mockClear();
  googleModelIdMock.mockClear();
  // Default: model returns a valid source. Per-call factory so each attempt
  // gets a fresh single-use partial stream (a shared generator would be
  // exhausted after the first attempt's iteration).
  streamTextMock.mockImplementation(() => fakeStream({ ...validGenerated }));
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
    expect(streamTextMock).toHaveBeenCalledTimes(1);
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

    const call = streamTextMock.mock.calls[0][0];
    expect(call.maxOutputTokens).toBe(60_000);
    expect(call.output).toEqual({
      __outputSpec: expect.objectContaining({
        name: "TwistSource",
        description: expect.stringContaining("files array"),
        schema: expect.anything(),
      }),
    });
    // Gemini 2.5+/3 caches large repeated prefixes implicitly — no provider
    // options needed, so instructions is a plain string.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("<SDK_DOCS>");
    expect(call.instructions).toContain("<TWIST_GUIDE>");
    // messages must contain ONLY the user message — a system entry here
    // would make ai@7's streamText throw before any network call.
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

    const call = streamTextMock.mock.calls[0][0];
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

    expect(streamTextMock).toHaveBeenCalledTimes(2);

    const firstUser = streamTextMock.mock.calls[0][0].messages.find(
      (m: any) => m.role === "user"
    );
    expect(firstUser.content).toContain("SPEC_MARKER_123");

    // Retry conversation appends the build-error feedback as the LAST turn
    // (not the first user message, which stays the original spec).
    const retryMessages = streamTextMock.mock.calls[1][0].messages;
    const retryUser = retryMessages[retryMessages.length - 1];
    expect(retryUser.role).toBe("user");
    expect(retryUser.content).toContain("failed to build");
    expect(retryUser.content).toContain("boom");
  });

  it("retries up to 3 times and then throws with the final errors", async () => {
    buildTwistMock.mockResolvedValue({ success: false, errors: ["still bad"] });

    await expect(
      generateTwist({ spec: "x", env: makeEnv() })
    ).rejects.toThrow(/Failed to generate valid twist after 3 attempts/);

    expect(streamTextMock).toHaveBeenCalledTimes(3);
    expect(buildTwistMock).toHaveBeenCalledTimes(3);
  });

  it("propagates a stream error to the caller exactly once", async () => {
    streamTextMock.mockReturnValueOnce(
      fakeStream(null, { error: new Error("stream boom") })
    );
    await expect(generateTwist({ spec: "hello", env: makeEnv() })).rejects.toThrow(
      "stream boom"
    );
    expect(buildTwistMock).not.toHaveBeenCalled();
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
    streamTextMock.mockReturnValueOnce(
      fakeStream(
        { ...validGenerated },
        {
          usage: { inputTokens: 100, outputTokens: 42 },
          providerMetadata: {
            anthropic: { cacheReadInputTokens: 70, cacheCreationInputTokens: 30 },
          },
        }
      )
    );
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

  it("announces each generated file once via onProgress while streaming", async () => {
    streamTextMock.mockReturnValueOnce(
      fakeStream(
        {
          displayName: "P",
          files: [
            { path: "index.ts", content: "a" },
            { path: "lib/util.ts", content: "b" },
          ],
          dependencies: [],
        },
        {
          partials: [
            { files: [{ path: "index.ts" }] },
            { files: [{ path: "index.ts" }, { path: "lib/util.ts" }] },
            { files: [{ path: "index.ts", content: "a" }, { path: "lib/util.ts", content: "b" }] },
          ],
        }
      )
    );
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const onProgress = vi.fn();
    await generateTwist({ spec: "hello", env: makeEnv(), onProgress });
    const writes = onProgress.mock.calls.map((c) => c[0]).filter((m: string) => m.startsWith("Writing "));
    expect(writes).toEqual(["Writing index.ts", "Writing lib/util.ts"]);
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
    streamTextMock.mockReturnValueOnce(
      fakeStream(
        { ...validGenerated },
        {
          usage: { inputTokens: 100, outputTokens: 42 },
          providerMetadata: { google: { cachedContentTokenCount: 55 } },
        }
      )
    );
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
    streamTextMock.mockReturnValueOnce(
      fakeStream({
        displayName: "Mapper",
        files: [
          { path: "index.ts", content: "export default class M {}" },
          { path: "lib/util.ts", content: "export const x = 1;" },
        ],
        dependencies: [{ name: "zod", version: "^4.0.0" }],
      })
    );
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
    streamTextMock.mockReturnValueOnce(
      fakeStream({
        displayName: "NoEntry",
        files: [{ path: "main.ts", content: "export {}" }],
        dependencies: [],
      })
    );
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

describe("multi-turn build-repair conversation", () => {
  it("keeps the spec in every attempt and appends assistant/error turns", async () => {
    buildTwistMock
      .mockResolvedValueOnce({ success: false, errors: ["Type check failed:\nTS2304"] })
      .mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "my spec text", env: makeEnv() });

    expect(streamTextMock).toHaveBeenCalledTimes(2);
    const first = streamTextMock.mock.calls[0][0].messages;
    const second = streamTextMock.mock.calls[1][0].messages;
    // Attempt 1: single user message containing the spec.
    expect(first).toHaveLength(1);
    expect(first[0].role).toBe("user");
    expect(first[0].content).toContain("my spec text");
    // Attempt 2: spec turn + assistant's prior output + error feedback.
    expect(second).toHaveLength(3);
    expect(second[0]).toEqual(first[0]);
    expect(second[1].role).toBe("assistant");
    expect(second[1].content).toContain('"index.ts"'); // array-shaped prior output
    expect(second[2].role).toBe("user");
    expect(second[2].content).toContain("Type check failed:");
    expect(second[2].content).toContain("Fix these and return the complete corrected twist.");
  });
});

describe("LLM retry policy", () => {
  it("retries transient errors with backoff and emits llm_retry", async () => {
    vi.useFakeTimers();
    try {
      streamTextMock
        .mockReturnValueOnce(fakeStream(null, { error: namedError("AI_APICallError", "overloaded", { statusCode: 529 }) }))
        .mockReturnValueOnce(fakeStream({ ...validGenerated }));
      buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
      const events: GenerateAttemptEvent[] = [];
      const done = generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
      await vi.runAllTimersAsync();
      await done;
      expect(streamTextMock).toHaveBeenCalledTimes(2);
      expect(events).toContainEqual({ type: "llm_retry", attempt: 1, reason: "transient", retry: 1 });
      // Only ONE llm_complete (the successful call).
      expect(events.filter((e) => e.type === "llm_complete")).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("gives up after two transient retries", async () => {
    vi.useFakeTimers();
    try {
      const boom = namedError("AI_APICallError", "overloaded", { statusCode: 529 });
      streamTextMock.mockReturnValue(fakeStream(null, { error: boom }));
      const done = generateTwist({ spec: "hello", env: makeEnv() });
      const assertion = expect(done).rejects.toThrow(/overloaded/);
      await vi.runAllTimersAsync();
      await assertion;
      expect(streamTextMock).toHaveBeenCalledTimes(3); // initial + 2 retries
    } finally {
      vi.useRealTimers();
    }
  });

  it("retries an output problem once with a corrective turn", async () => {
    streamTextMock
      .mockReturnValueOnce(
        fakeStream(null, {
          error: namedError("AI_NoOutputGeneratedError", "no output generated"),
          finishReason: "length",
        })
      )
      .mockReturnValueOnce(fakeStream({ ...validGenerated }));
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });
    const events: GenerateAttemptEvent[] = [];
    await generateTwist({ spec: "hello", env: makeEnv(), onEvent: (e) => events.push(e) });
    expect(streamTextMock).toHaveBeenCalledTimes(2);
    const secondMessages = streamTextMock.mock.calls[1][0].messages;
    expect(secondMessages[secondMessages.length - 1].role).toBe("user");
    expect(secondMessages[secondMessages.length - 1].content).toMatch(/did not produce a valid twist object/);
    expect(events).toContainEqual({ type: "llm_retry", attempt: 1, reason: "output", retry: 1 });
  });

  it("gives up after one output-problem retry", async () => {
    const bad = namedError("AI_NoOutputGeneratedError", "no output generated");
    streamTextMock.mockReturnValue(fakeStream(null, { error: bad }));
    await expect(generateTwist({ spec: "hello", env: makeEnv() })).rejects.toThrow(/no output generated/);
    expect(streamTextMock).toHaveBeenCalledTimes(2); // initial + 1 retry
  });

  it("enriches output-problem errors with the stream finish reason", async () => {
    const bad = namedError("AI_NoOutputGeneratedError", "no output generated");
    streamTextMock.mockReturnValue(fakeStream(null, { error: bad, finishReason: "length" }));
    await expect(generateTwist({ spec: "hello", env: makeEnv() })).rejects.toMatchObject({
      name: "AI_NoOutputGeneratedError",
      finishReason: "length",
    });
  });
});
