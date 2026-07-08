import { afterEach, describe, expect, it, vi } from "vitest";

import type { PostHog } from "posthog-node";

import type { Bindings, WebhookMessage } from "../env";
import { processWebhooks } from "./webhook";

// invokeWebhookCallback is the only collaborator that throws; mock it so each
// test can inject a specific provider error and assert the consumer's taxonomy.
const { invokeWebhookCallback } = vi.hoisted(() => ({
  invokeWebhookCallback: vi.fn(),
}));

vi.mock("../twist/invoke-webhook", () => ({ invokeWebhookCallback }));

// `../webhook` re-exports the full Hono app (rate limiter → `cloudflare:workers`),
// which Vite can't resolve from a transitive CJS dependency. We provide `body`
// on every message so `parseBodyFromRaw` is never called — stub the module so
// the heavy import chain never loads.
vi.mock("../webhook", () => ({ parseBodyFromRaw: vi.fn() }));

function makeMessage(attempts = 1) {
  return {
    id: "msg-1",
    timestamp: new Date(),
    attempts,
    body: {
      type: "webhook" as const,
      token: "tok_abcdefgh",
      method: "onWebhook",
      headers: {},
      params: {},
      body: {},
    },
    ack: vi.fn(),
    retry: vi.fn(),
  };
}

async function run(error: Error, { attempts = 1 } = {}) {
  invokeWebhookCallback.mockRejectedValueOnce(error);
  const message = makeMessage(attempts);
  const batch = {
    queue: "webhook-queue",
    messages: [message],
  } as unknown as MessageBatch<WebhookMessage>;
  const captureException = vi.fn();
  const postHog = { captureException } as unknown as PostHog;
  const ctx = { exports: {} } as unknown as Parameters<typeof processWebhooks>[2];
  await processWebhooks(batch, {} as Bindings, ctx, postHog);
  return { message, captureException };
}

describe("processWebhooks routes connector-callback messages", () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it("invokes the callback token with the pre-built connector args, then acks", async () => {
    // Unipile message/invitation/relation events are enqueued as
    // `connector-callback` messages so the slow connector RPC runs durably in
    // the consumer (with retries) instead of inline in the inbound webhook
    // request, where it was canceled mid-save.
    invokeWebhookCallback.mockResolvedValueOnce(undefined);
    const message = {
      id: "msg-cc",
      timestamp: new Date(),
      attempts: 1,
      body: {
        type: "connector-callback" as const,
        token: "doid:tok",
        args: [{ kind: "message.received", chatId: "c1", messageId: "m1" }],
      },
      ack: vi.fn(),
      retry: vi.fn(),
    };
    const batch = {
      queue: "webhook-queue",
      messages: [message],
    } as unknown as MessageBatch<WebhookMessage>;
    const postHog = { captureException: vi.fn() } as unknown as PostHog;
    const ctx = { exports: {} } as unknown as Parameters<typeof processWebhooks>[2];

    await processWebhooks(batch, {} as Bindings, ctx, postHog);

    expect(invokeWebhookCallback).toHaveBeenCalledTimes(1);
    expect(invokeWebhookCallback).toHaveBeenCalledWith(
      {},
      ctx,
      "doid:tok",
      { kind: "message.received", chatId: "c1", messageId: "m1" }
    );
    expect(message.ack).toHaveBeenCalledTimes(1);
    expect(message.retry).not.toHaveBeenCalled();
  });
});

describe("processWebhooks suppresses expected provider errors", () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it("retries a downstream rate-limit error without paging PostHog", async () => {
    // Gmail per-user-per-minute quota (PostHog 019ef5be). Self-resolves once the
    // provider's rate window clears, so retry without capturing — mirroring
    // Tasks.processQueue.
    const { message, captureException } = await run(
      new Error(
        'GmailApiError: Gmail API error: 403 Forbidden - {"error":{"errors":' +
          '[{"reason":"rateLimitExceeded"}]}}'
      )
    );

    expect(message.retry).toHaveBeenCalledTimes(1);
    expect(message.ack).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
  });

  it("retries a Durable Object storage-startup reset without paging PostHog", async () => {
    // Cloudflare failed to start up the CALLBACKS DO's storage (the
    // validateAndLoad hop in invoke-webhook) and reset the object:
    // "Internal error while starting up Durable Object storage caused object
    // to be reset; reference = <id>" (PostHog issue 019f277a: 214 captures /
    // 158 users in one day). Platform noise, self-resolves on retry — warn +
    // retry, never page.
    const { message, captureException } = await run(
      new Error(
        "Internal error while starting up Durable Object storage caused " +
          "object to be reset; reference = q1jnt2ahu9rjefmqe6npchv9"
      )
    );

    expect(message.retry).toHaveBeenCalledTimes(1);
    expect(message.ack).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
  });

  it("reports a Durable Object reset ONCE when retries are exhausted, then acks", async () => {
    // The webhook queue has no DLQ, so after max_retries Cloudflare silently
    // drops the message. A reset that persists to the attempt cap (a poisoned
    // DO, or a platform incident outlasting the retry window) must leave one
    // signal — the same isQueueRetryExhausted backstop the transient branch
    // uses. A blip that recovers on attempts 1-2 never reaches this.
    const { message, captureException } = await run(
      new Error(
        "Internal error in Durable Object storage caused object to be " +
          "reset; reference = q1jnt2ahu9rjefmqe6npchv9"
      ),
      { attempts: 3 }
    );

    expect(message.ack).toHaveBeenCalledTimes(1);
    expect(message.retry).not.toHaveBeenCalled();
    expect(captureException).toHaveBeenCalledTimes(1);
    expect(captureException).toHaveBeenCalledWith(
      expect.any(Error),
      undefined,
      expect.objectContaining({ outcome: "do_reset_exhausted", attempts: 3 })
    );
  });

  it("acks a terminal auth error without paging PostHog", async () => {
    // Revoked/expired token: retrying loops the same 401 to the cap. ACK to drop
    // it; the app drives re-auth via needs_reauth_at.
    const { message, captureException } = await run(
      new Error("Gmail API error: 401 Unauthorized - Invalid Credentials")
    );

    expect(message.ack).toHaveBeenCalledTimes(1);
    expect(message.retry).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
  });
});
