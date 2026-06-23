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

function makeMessage() {
  return {
    id: "msg-1",
    timestamp: new Date(),
    attempts: 1,
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

async function run(error: Error) {
  invokeWebhookCallback.mockRejectedValueOnce(error);
  const message = makeMessage();
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
