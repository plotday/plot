import { describe, it, expect } from "vitest";
import {
  normalizeExceptionMessage,
  exceptionFingerprintBeforeSend,
} from "./posthog-fingerprint";

type TestEvent = {
  event: string;
  distinctId?: string;
  properties?: Record<string, unknown>;
};

// Build a minimal posthog-node `$exception` EventMessage.
function exceptionEvent(
  exceptions: { type?: string; value: string }[],
  extraProps: Record<string, unknown> = {},
): TestEvent {
  return {
    event: "$exception",
    distinctId: "u1",
    properties: {
      $exception_list: exceptions.map((e) => ({
        type: e.type ?? "Error",
        value: e.value,
        mechanism: { handled: true },
      })),
      ...extraProps,
    },
  };
}

function fingerprintOf(
  exceptions: { type?: string; value: string }[],
  extraProps: Record<string, unknown> = {},
) {
  const out = exceptionFingerprintBeforeSend(
    exceptionEvent(exceptions, extraProps),
  );
  return out?.properties?.$exception_fingerprint as string | undefined;
}

describe("normalizeExceptionMessage", () => {
  it("leaves messages with no volatile tokens untouched", () => {
    expect(normalizeExceptionMessage("Worker exceeded memory limit.")).toBe(
      "Worker exceeded memory limit.",
    );
  });

  it("strips 'reference = <opaque id>' tails so DO resets group", () => {
    const a = normalizeExceptionMessage(
      "Internal error in Durable Object storage caused object to be reset; reference = 26ou2mt86hahckspbj7bpcar",
    );
    const b = normalizeExceptionMessage(
      "Internal error in Durable Object storage caused object to be reset; reference = zzz9aa0bb1cc2dd3ee4ff5gg",
    );
    expect(a).toBe(b);
    expect(a).toContain("<id>");
  });

  it("normalizes URL paths and query strings", () => {
    const a = normalizeExceptionMessage(
      "UnipileApiError: Unipile GET /v2/acc_01kwdehhnneh5ve0xf8qkv7qkf/chats/CLASSIC_2-YzhlM2EzNTItNGIzMC00ZTg3/messages?limit=20 returned 429",
    );
    const b = normalizeExceptionMessage(
      "UnipileApiError: Unipile GET /v2/acc_99zzabcdefghijklmnopqrst/chats/CLASSIC_2-QUJDREVGR0hJSktMTU5PUFFS/messages?limit=20 returned 429",
    );
    // Same endpoint shape + status class -> same key regardless of account/chat.
    expect(a).toBe(b);
    expect(a).toBe(
      "UnipileApiError: Unipile GET /v2/<id>/chats/<id>/messages returned 4xx",
    );
  });

  it("collapses HTTP status to its class but keeps 4xx vs 5xx distinct", () => {
    const clientErr = normalizeExceptionMessage("Upstream returned 429");
    const serverErr = normalizeExceptionMessage("Upstream returned 503");
    expect(clientErr).toBe("Upstream returned 4xx");
    expect(serverErr).toBe("Upstream returned 5xx");
    expect(clientErr).not.toBe(serverErr);
  });

  it("caps length to keep fingerprints bounded", () => {
    expect(normalizeExceptionMessage("word ".repeat(100)).length).toBe(200);
  });
});

describe("exceptionFingerprintBeforeSend", () => {
  it("passes through non-exception events unchanged", () => {
    const ev: TestEvent = {
      event: "$pageview",
      properties: { $current_url: "/x" },
    };
    const out = exceptionFingerprintBeforeSend(ev);
    expect(out).toBe(ev);
    expect(out?.properties?.$exception_fingerprint).toBeUndefined();
  });

  it("passes through null events", () => {
    expect(exceptionFingerprintBeforeSend(null)).toBeNull();
  });

  it("does not overwrite a caller-provided fingerprint", () => {
    const fp = fingerprintOf([{ value: "boom" }], {
      $exception_fingerprint: "custom-code",
    });
    expect(fp).toBe("custom-code");
  });

  it("leaves events with no $exception_list alone", () => {
    const ev: TestEvent = { event: "$exception", properties: {} };
    const out = exceptionFingerprintBeforeSend(ev);
    expect(out?.properties?.$exception_fingerprint).toBeUndefined();
  });

  it("gives the six real-world messages from issue 019ed581 distinct fingerprints", () => {
    const messages = [
      "Queue send failed: Bad Gateway",
      "UnipileApiError: Unipile GET /v2/acc_01kwdehhnneh5ve0xf8qkv7qkf/chats/CLASSIC_2-abc/messages?limit=20 returned 429",
      "Internal error in Durable Object storage caused object to be reset; reference = 26ou2mt86hahckspbj7bpcar",
      "Durable Object storage operation exceeded timeout which caused object to be reset.",
      "Worker exceeded memory limit.",
      "error: Timed out while waiting for an open slot in the pool.",
    ];
    const fingerprints = messages.map((value) => fingerprintOf([{ value }]));
    expect(new Set(fingerprints).size).toBe(messages.length);
  });

  it("keeps the same error kind across different ids in one fingerprint", () => {
    const fp1 = fingerprintOf([
      {
        value:
          "UnipileApiError: Unipile GET /v2/acc_aaaaaaaaaaaaaaaaaaaa/chats/x1abcdefghijklmnopqrs/messages?limit=20 returned 429",
      },
    ]);
    const fp2 = fingerprintOf([
      {
        value:
          "UnipileApiError: Unipile GET /v2/acc_bbbbbbbbbbbbbbbbbbbb/chats/y2abcdefghijklmnopqrs/messages?limit=50 returned 429",
      },
    ]);
    expect(fp1).toBe(fp2);
  });

  it("distinguishes chained exceptions by combining the list", () => {
    const single = fingerprintOf([{ type: "TypeError", value: "a" }]);
    const chained = fingerprintOf([
      { type: "TypeError", value: "a" },
      { type: "Error", value: "root cause" },
    ]);
    expect(single).not.toBe(chained);
    expect(chained).toContain("<<<");
  });
});
