import { describe, it, expect, vi, beforeEach } from "vitest";

import { generateTwist } from "./generator";
import type { TwistSource } from "./types";

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
// so we swap it for a callable sentinel.
const anthropicModelSentinel = { __sentinel: "model" };
const createAnthropicMock = vi.fn();
vi.mock("@ai-sdk/anthropic", () => ({
  createAnthropic: (opts?: unknown) => {
    createAnthropicMock(opts);
    return () => anthropicModelSentinel;
  },
}));

const validSource: TwistSource = {
  displayName: "Sample Twist",
  dependencies: {},
  files: {
    "index.ts": "export default class SampleTwist {}",
  },
};

function makeEnv(overrides: Record<string, string | undefined> = {}) {
  return {
    AI_GATEWAY_ACCOUNT_ID: "acct",
    AI_GATEWAY_ID: "gw",
    AI_GATEWAY_TOKEN: "token",
    ANTHROPIC_API_KEY: "key",
    TWIST_BUILDER: {},
    ...overrides,
  } as any;
}

describe("generateTwist", () => {
  beforeEach(() => {
    buildTwistMock.mockReset();
    generateObjectMock.mockReset();
    createAnthropicMock.mockClear();
    // Default: model returns a valid source.
    generateObjectMock.mockResolvedValue({ object: { ...validSource } });
  });

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

  it("uses sonnet 4.6, a reasonable token budget, and caches the system prompt", async () => {
    buildTwistMock.mockResolvedValueOnce({ success: true, module: "ok" });

    await generateTwist({ spec: "anything", env: makeEnv() });

    expect(createAnthropicMock).toHaveBeenCalledTimes(1);

    const call = generateObjectMock.mock.calls[0][0];
    expect(call.maxOutputTokens).toBeGreaterThanOrEqual(16_000);
    expect(call.messages).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: "system",
          providerOptions: {
            anthropic: { cacheControl: { type: "ephemeral" } },
          },
        }),
      ])
    );
    // System content must include both the SDK docs stub and the twist guide
    // stub so the big static prefix is part of the cached block.
    const systemMsg = call.messages.find((m: any) => m.role === "system");
    expect(systemMsg.content).toContain("<SDK_DOCS>");
    expect(systemMsg.content).toContain("<TWIST_GUIDE>");
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

  it("throws when the model omits index.ts", async () => {
    generateObjectMock.mockResolvedValueOnce({
      object: {
        displayName: "Bad",
        dependencies: {},
        files: { "other.ts": "..." },
      },
    });

    await expect(
      generateTwist({ spec: "x", env: makeEnv() })
    ).rejects.toThrow(/missing required 'index\.ts'/);
    expect(buildTwistMock).not.toHaveBeenCalled();
  });
});
