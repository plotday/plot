import { describe, expect, it, vi } from "vitest";

import { isTransientAiError, promptWithRetry } from "./retry";

describe("isTransientAiError", () => {
  it.each([
    "429 Too Many Requests",
    "rate limit exceeded",
    "model is overloaded",
    "Request timeout",
    "fetch failed",
    "internal server error (500)",
    "503 Service Unavailable",
  ])("classifies '%s' as transient", (msg) => {
    expect(isTransientAiError(new Error(msg))).toBe(true);
  });

  it("does not classify logic errors as transient", () => {
    expect(isTransientAiError(new Error("No model available for provider"))).toBe(false);
    expect(isTransientAiError(new Error("AI features are disabled by the user."))).toBe(false);
  });
});

describe("promptWithRetry", () => {
  it("retries once on transient failure", async () => {
    const prompt = vi
      .fn()
      .mockRejectedValueOnce(new Error("overloaded"))
      .mockResolvedValueOnce({ text: "ok" });
    const out = await promptWithRetry({ prompt } as any, { messages: [] } as any, 1);
    expect(out.text).toBe("ok");
    expect(prompt).toHaveBeenCalledTimes(2);
  });

  it("rethrows non-transient errors immediately", async () => {
    const prompt = vi.fn().mockRejectedValue(new Error("bad schema"));
    await expect(promptWithRetry({ prompt } as any, {} as any, 1)).rejects.toThrow("bad schema");
    expect(prompt).toHaveBeenCalledTimes(1);
  });
});
