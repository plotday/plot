import { afterEach, describe, expect, it, vi } from "vitest";

import type { Bindings } from "../env";
import { exceptionFingerprint } from "../utils/exception-fingerprint";
import { handleTwistOperation } from "./error-handling";

// PostHog is instantiated inside handleTwistOperation, so hoist the spies and
// hand them back from the mocked constructor.
const { captureException, shutdown } = vi.hoisted(() => ({
  captureException: vi.fn(),
  shutdown: vi.fn(async () => {}),
}));

vi.mock("posthog-node", () => ({
  PostHog: vi.fn(() => ({ captureException, shutdown })),
}));

function makeContext(extra?: { userId?: string | null }) {
  return {
    env: {
      POSTHOG_API_KEY: "phc_test",
      POSTHOG_HOST: "https://us.i.posthog.com",
      TWIST_LOGS_QUEUE: { send: vi.fn(async () => {}) },
      TWIST_MODULES_BUCKET: { get: vi.fn(async () => null) },
    } as unknown as Bindings,
    id: "twist-1",
    version: "1.0.0",
    environment: "public" as const,
    ctx: { waitUntil: vi.fn() },
    ...extra,
  };
}

describe("handleTwistOperation exception fingerprint", () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it("captures a type+message fingerprint so distinct errors don't collapse", async () => {
    const message =
      "Sync state not found for project 1c043f04-7c09-4eb9-8d9f-b0ef8b23b52a";

    await expect(
      handleTwistOperation(
        "dispatch sourceMethod: onThreadToDo",
        async () => {
          throw new Error(message);
        },
        makeContext()
      )
    ).rejects.toThrow(message);

    expect(captureException).toHaveBeenCalledTimes(1);
    // Tracker.captureException(error, distinctId, additionalProperties)
    const properties = captureException.mock.calls[0][2];
    expect(properties.$exception_fingerprint).toBe(
      exceptionFingerprint("Error", message)
    );
  });

  it("gives two errors on the same stack different fingerprints", async () => {
    const fingerprintFor = async (message: string): Promise<string> => {
      await expect(
        handleTwistOperation(
          "op",
          async () => {
            throw new Error(message);
          },
          makeContext()
        )
      ).rejects.toThrow();
      const lastCall = captureException.mock.calls.at(-1);
      return lastCall![2].$exception_fingerprint as string;
    };

    // Both are non-transient (so they reach the capture path) but distinct.
    const fpA = await fingerprintFor(
      "Sync state not found for project 1c043f04-7c09-4eb9-8d9f-b0ef8b23b52a"
    );
    const fpB = await fingerprintFor(
      "error: canceling statement due to statement timeout"
    );

    expect(fpA).not.toBe(fpB);
  });

  it("attributes the capture to the owning user when provided", async () => {
    const userId = "00000000-0000-0000-0000-0000000000aa";
    await expect(
      handleTwistOperation(
        "op",
        async () => {
          throw new Error("boom");
        },
        makeContext({ userId })
      )
    ).rejects.toThrow();

    // Tracker.captureException(error, distinctId, additionalProperties)
    expect(captureException.mock.calls[0][1]).toBe(userId);
  });

  it("falls back to a stable twist-scoped id (never a random per-event UUID) when no user is known", async () => {
    await expect(
      handleTwistOperation(
        "op",
        async () => {
          throw new Error("boom");
        },
        makeContext() // no userId
      )
    ).rejects.toThrow();

    // Must be deterministic (so anonymous twist errors collapse onto one
    // synthetic identity instead of inflating "users affected" with a fresh
    // random UUID per event).
    expect(captureException.mock.calls[0][1]).toBe("twist:twist-1");
  });
});

describe("handleTwistOperation suppresses expected provider errors", () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it("does not capture or log a downstream rate-limit error, but still rethrows", async () => {
    // The exact Gmail per-user-per-minute quota body that floods PostHog
    // (issue 019ef5be): a 403 whose message carries `rateLimitExceeded` /
    // `RATE_LIMIT_EXCEEDED` / `Quota exceeded`. The queue consumer
    // (Tasks.processQueue) already retries these via isRateLimitError without
    // paging, so handleTwistOperation must not capture them first.
    const message =
      'GmailApiError: Gmail API error: 403 Forbidden - {"error":{"code":403,' +
      '"message":"Quota exceeded for quota metric \'Queries\'","errors":' +
      '[{"reason":"rateLimitExceeded"}],"status":"PERMISSION_DENIED"}}';
    const context = makeContext();

    await expect(
      handleTwistOperation(
        "op",
        async () => {
          throw new Error(message);
        },
        context
      )
    ).rejects.toThrow(message);

    expect(captureException).not.toHaveBeenCalled();
    expect(context.env.TWIST_LOGS_QUEUE.send).not.toHaveBeenCalled();
  });

  it("does not capture or log a terminal auth error, but still rethrows", async () => {
    // Revoked/expired OAuth token. Tasks.processQueue ACKs these via
    // isAuthError (the user re-auths); paging PostHog is noise.
    const message = "Gmail API error: 401 Unauthorized - Invalid Credentials";
    const context = makeContext();

    await expect(
      handleTwistOperation(
        "op",
        async () => {
          throw new Error(message);
        },
        context
      )
    ).rejects.toThrow(message);

    expect(captureException).not.toHaveBeenCalled();
    expect(context.env.TWIST_LOGS_QUEUE.send).not.toHaveBeenCalled();
  });
});
