import { afterEach, describe, expect, it, vi } from "vitest";

import type { Actor, Thread } from "@plotday/twister/plot";

import { GmailApi, GmailApiError } from "./gmail-api";
import {
  type GmailSyncHost,
  type PendingWriteBack,
  MAX_WRITEBACK_ATTEMPTS,
  MAX_WRITEBACK_RETRY_PER_BATCH,
  mergePendingWriteBack,
  onThreadReadFn,
  onThreadToDoFn,
  processWriteBackRetryFn,
} from "./sync";

/** In-memory GmailSyncHost exposing the queueWriteBackRetry continuation spy. */
function makeHost(opts: { noToken?: boolean } = {}): {
  host: GmailSyncHost;
  store: Map<string, unknown>;
  queueWriteBackRetry: ReturnType<typeof vi.fn>;
} {
  const store = new Map<string, unknown>([["enabled_channels", ["INBOX"]]]);
  const queueWriteBackRetry = vi.fn(async () => {});
  const host = {
    id: "twist-instance-1",
    get: vi.fn(async (key: string) => (store.has(key) ? store.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      store.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      store.delete(key);
    }),
    tools: {
      integrations: {
        get: vi.fn(async () => (opts.noToken ? null : { token: "tok", scopes: [] })),
        saveLink: vi.fn(async () => null),
        channelSyncCompleted: vi.fn(async () => {}),
        setThreadToDo: vi.fn(async () => {}),
      },
      files: { read: vi.fn() },
      network: { createWebhook: vi.fn(), deleteWebhook: vi.fn() },
      store: {
        acquireLock: vi.fn(async () => true),
        releaseLock: vi.fn(async () => {}),
        list: vi.fn(async () => []),
      },
    },
    scheduler: {
      onGmailWebhook: undefined,
      setupMailboxWebhook: vi.fn(async () => {}),
      renewMailboxWatch: vi.fn(async () => {}),
      scheduleMailboxRenewal: vi.fn(async () => {}),
      scheduleSelfHealCheck: vi.fn(async () => {}),
      cancelScheduledTask: vi.fn(async () => {}),
      queueIncrementalSync: vi.fn(async () => {}),
      queueWriteBackRetry,
    },
  } as unknown as GmailSyncHost;
  return { host, store, queueWriteBackRetry };
}

function threadWith(threadId: string): Thread {
  return { id: "T", meta: { threadId, channelId: "INBOX" } } as unknown as Thread;
}

const actor = {} as Actor;
const rateLimit = () => new GmailApiError(429, "Too Many Requests", "rate");

afterEach(() => vi.restoreAllMocks());

describe("onThreadToDoFn / onThreadReadFn — defer on rate-limit", () => {
  it("onThreadToDoFn defers the star write-back instead of dropping it", async () => {
    vi.spyOn(GmailApi.prototype, "modifyThread").mockRejectedValue(rateLimit());
    const { host, store, queueWriteBackRetry } = makeHost();

    await expect(
      onThreadToDoFn(host, threadWith("gt1"), actor, true, {})
    ).resolves.toBeUndefined();

    expect(store.get("writeback_pending")).toEqual([
      { kind: "todo", threadId: "gt1", channelId: "INBOX", value: true, attempts: 0 },
    ]);
    expect(queueWriteBackRetry).toHaveBeenCalledTimes(1);
  });

  it("onThreadReadFn defers the read write-back on rate-limit", async () => {
    vi.spyOn(GmailApi.prototype, "modifyThread").mockRejectedValue(rateLimit());
    const { host, store, queueWriteBackRetry } = makeHost();

    await expect(
      onThreadReadFn(host, threadWith("gt2"), actor, false)
    ).resolves.toBeUndefined();

    expect(store.get("writeback_pending")).toEqual([
      { kind: "read", threadId: "gt2", channelId: "INBOX", value: false, attempts: 0 },
    ]);
    expect(queueWriteBackRetry).toHaveBeenCalledTimes(1);
  });

  it("rethrows non-rate-limit errors (real failures stay visible)", async () => {
    vi.spyOn(GmailApi.prototype, "modifyThread").mockRejectedValue(
      new GmailApiError(404, "Not Found", "gone")
    );
    const { host, store, queueWriteBackRetry } = makeHost();

    await expect(
      onThreadToDoFn(host, threadWith("gt3"), actor, true, {})
    ).rejects.toMatchObject({ status: 404 });

    expect(store.has("writeback_pending")).toBe(false);
    expect(queueWriteBackRetry).not.toHaveBeenCalled();
  });
});

describe("processWriteBackRetryFn — bounded, self-terminating drain", () => {
  it("does nothing when the queue is empty", async () => {
    const modify = vi.spyOn(GmailApi.prototype, "modifyThread");
    const { host, queueWriteBackRetry } = makeHost();

    await processWriteBackRetryFn(host);

    expect(modify).not.toHaveBeenCalled();
    expect(queueWriteBackRetry).not.toHaveBeenCalled();
  });

  it("applies pending write-backs and clears the queue (no re-queue)", async () => {
    const modify = vi.spyOn(GmailApi.prototype, "modifyThread").mockResolvedValue(undefined);
    const { host, store, queueWriteBackRetry } = makeHost();
    store.set("writeback_pending", [
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: 0 },
      { kind: "read", threadId: "b", channelId: "INBOX", value: false, attempts: 1 },
    ] satisfies PendingWriteBack[]);

    await processWriteBackRetryFn(host);

    expect(modify).toHaveBeenCalledTimes(2);
    expect(store.has("writeback_pending")).toBe(false);
    expect(queueWriteBackRetry).not.toHaveBeenCalled();
  });

  it("keeps and re-queues a still-rate-limited item with a bumped attempt", async () => {
    vi.spyOn(GmailApi.prototype, "modifyThread").mockRejectedValue(rateLimit());
    const { host, store, queueWriteBackRetry } = makeHost();
    store.set("writeback_pending", [
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: 0 },
    ] satisfies PendingWriteBack[]);

    await processWriteBackRetryFn(host);

    expect(store.get("writeback_pending")).toEqual([
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: 1 },
    ]);
    expect(queueWriteBackRetry).toHaveBeenCalledTimes(1);
  });

  it("abandons a write-back after MAX_WRITEBACK_ATTEMPTS and stops re-queuing", async () => {
    vi.spyOn(GmailApi.prototype, "modifyThread").mockRejectedValue(rateLimit());
    const { host, store, queueWriteBackRetry } = makeHost();
    store.set("writeback_pending", [
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: MAX_WRITEBACK_ATTEMPTS - 1 },
    ] satisfies PendingWriteBack[]);

    await processWriteBackRetryFn(host);

    expect(store.has("writeback_pending")).toBe(false);
    expect(queueWriteBackRetry).not.toHaveBeenCalled();
  });

  it("bounds the pass and re-queues the overflow", async () => {
    const modify = vi.spyOn(GmailApi.prototype, "modifyThread").mockResolvedValue(undefined);
    const overflow = 3;
    const items: PendingWriteBack[] = Array.from(
      { length: MAX_WRITEBACK_RETRY_PER_BATCH + overflow },
      (_, i) => ({ kind: "todo", threadId: `t${i}`, channelId: "INBOX", value: true, attempts: 0 })
    );
    const { host, store, queueWriteBackRetry } = makeHost();
    store.set("writeback_pending", items);

    await processWriteBackRetryFn(host);

    expect(modify).toHaveBeenCalledTimes(MAX_WRITEBACK_RETRY_PER_BATCH);
    expect((store.get("writeback_pending") as PendingWriteBack[]).length).toBe(overflow);
    expect(queueWriteBackRetry).toHaveBeenCalledTimes(1);
  });

  it("drops a write-back whose channel lost its token (state still lives in Plot)", async () => {
    const modify = vi.spyOn(GmailApi.prototype, "modifyThread");
    const { host, store, queueWriteBackRetry } = makeHost({ noToken: true });
    store.set("writeback_pending", [
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: 0 },
    ] satisfies PendingWriteBack[]);

    await processWriteBackRetryFn(host);

    expect(modify).not.toHaveBeenCalled();
    expect(store.has("writeback_pending")).toBe(false);
    expect(queueWriteBackRetry).not.toHaveBeenCalled();
  });
});

describe("mergePendingWriteBack", () => {
  it("replaces an existing kind+threadId, resetting attempts (last-write-wins)", () => {
    const merged = mergePendingWriteBack(
      [{ kind: "todo", threadId: "a", channelId: "INBOX", value: false, attempts: 3 }],
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true }
    );
    expect(merged).toEqual([
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true, attempts: 0 },
    ]);
  });

  it("keeps distinct kinds for the same thread", () => {
    const merged = mergePendingWriteBack(
      [{ kind: "read", threadId: "a", channelId: "INBOX", value: true, attempts: 0 }],
      { kind: "todo", threadId: "a", channelId: "INBOX", value: true }
    );
    expect(merged).toHaveLength(2);
  });
});
