import { describe, expect, it, vi } from "vitest";

import type { RunMessage } from "./tasks";
import { Tasks } from "./tasks";

// invokeWebhookCallback is the per-message work; mock it to observe
// per-instance concurrency inside processQueue.
const { invokeWebhookCallback } = vi.hoisted(() => ({
  invokeWebhookCallback: vi.fn(),
}));

vi.mock("../invoke-webhook", () => ({
  invokeWebhookCallback,
}));

vi.mock("posthog-node", () => ({
  PostHog: vi.fn(() => ({
    captureException: vi.fn(),
    shutdown: vi.fn(async () => {}),
  })),
}));

type FakeMessage = Message<RunMessage> & {
  acked: boolean;
  retried: boolean;
};

function makeMessage(twistInstanceId: string, token: string): FakeMessage {
  const message = {
    id: `id-${token}`,
    timestamp: new Date(),
    attempts: 1,
    body: { twistInstanceId, path: [], token, queuedAt: Date.now() },
    acked: false,
    retried: false,
    ack() {
      this.acked = true;
    },
    retry() {
      this.retried = true;
    },
  };
  return message as unknown as FakeMessage;
}

function makeBatch(messages: FakeMessage[]): MessageBatch<RunMessage> {
  return {
    queue: "run-test",
    messages,
    ackAll: () => {},
    retryAll: () => {},
  } as unknown as MessageBatch<RunMessage>;
}

const env = {} as never;
const ctx = { exports: {} } as never;
const postHog = new (await import("posthog-node")).PostHog("k");

describe("Tasks.processQueue per-instance dispatch", () => {
  it("never runs two messages for the same twist instance concurrently", async () => {
    const active = new Map<string, number>();
    const maxActive = new Map<string, number>();

    invokeWebhookCallback.mockImplementation(
      async (_env, _ctx, token: string) => {
        const instance = token.split("/")[0];
        const now = (active.get(instance) ?? 0) + 1;
        active.set(instance, now);
        maxActive.set(instance, Math.max(maxActive.get(instance) ?? 0, now));
        // Yield so batch-mates get a chance to start (which would push the
        // active count above 1 if dispatch weren't serialized per instance).
        await new Promise((resolve) => setTimeout(resolve, 5));
        active.set(instance, active.get(instance)! - 1);
        return undefined;
      }
    );

    const messages = [
      makeMessage("instance-a", "instance-a/1"),
      makeMessage("instance-a", "instance-a/2"),
      makeMessage("instance-b", "instance-b/1"),
      makeMessage("instance-a", "instance-a/3"),
      makeMessage("instance-b", "instance-b/2"),
    ];

    await Tasks.processQueue(env, ctx, makeBatch(messages), postHog);

    expect(maxActive.get("instance-a")).toBe(1);
    expect(maxActive.get("instance-b")).toBe(1);
    expect(messages.every((message) => message.acked)).toBe(true);
  });

  it("runs different twist instances concurrently", async () => {
    let concurrentInstances = 0;
    let maxConcurrentInstances = 0;

    invokeWebhookCallback.mockImplementation(async () => {
      concurrentInstances += 1;
      maxConcurrentInstances = Math.max(
        maxConcurrentInstances,
        concurrentInstances
      );
      await new Promise((resolve) => setTimeout(resolve, 5));
      concurrentInstances -= 1;
      return undefined;
    });

    const messages = [
      makeMessage("instance-a", "instance-a/1"),
      makeMessage("instance-b", "instance-b/1"),
      makeMessage("instance-c", "instance-c/1"),
    ];

    await Tasks.processQueue(env, ctx, makeBatch(messages), postHog);

    expect(maxConcurrentInstances).toBe(3);
    expect(messages.every((message) => message.acked)).toBe(true);
  });

  it("a failing message does not block the rest of its instance's group", async () => {
    invokeWebhookCallback.mockImplementation(
      async (_env, _ctx, token: string) => {
        if (token === "instance-a/1") {
          // Non-transient, non-callback error → failure_retry path.
          throw new Error("boom");
        }
        return undefined;
      }
    );

    const failing = makeMessage("instance-a", "instance-a/1");
    const following = makeMessage("instance-a", "instance-a/2");

    await Tasks.processQueue(env, ctx, makeBatch([failing, following]), postHog);

    expect(failing.retried).toBe(true);
    expect(following.acked).toBe(true);
  });
});
