import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  GmailApi,
  GmailApiError,
  type GmailThread,
  isGmailNotFoundError,
  syncGmailMailboxIncremental,
} from "./gmail-api";
import {
  type GmailSyncHost,
  type IncrementalState,
  incrementalSyncBatchFn,
  selfHealCheckFn,
} from "./sync";

/**
 * History entry shape the mocks emit: one message per thread, with the label
 * set that Gmail would report for it.
 */
type Change = {
  threadId: string;
  labelIds?: string[];
  /** Which history field carries the change (default `messagesAdded`). */
  via?: "messagesAdded" | "labelsAdded";
};

/** GmailApi mock exposing only getHistory + getThread, with per-thread errors. */
function mockApi(opts: {
  changes: Change[];
  newHistoryId?: string;
  throwOn?: Map<string, unknown>;
}): { api: GmailApi; getThread: ReturnType<typeof vi.fn> } {
  const getThread = vi.fn(async (id: string): Promise<GmailThread> => {
    const error = opts.throwOn?.get(id);
    if (error) throw error;
    return { id, historyId: "h", messages: [] } as unknown as GmailThread;
  });
  const getHistory = vi.fn(async () => ({
    history: opts.changes.map((change) => ({
      id: `hist-${change.threadId}`,
      [change.via ?? "messagesAdded"]: [
        {
          message: {
            id: `m-${change.threadId}`,
            threadId: change.threadId,
            labelIds: change.labelIds ?? ["INBOX"],
          },
        },
      ],
    })),
    historyId: opts.newHistoryId ?? "999",
  }));
  return { api: { getHistory, getThread } as unknown as GmailApi, getThread };
}

describe("isGmailNotFoundError", () => {
  it("is true for a 404", () => {
    expect(
      isGmailNotFoundError(
        new GmailApiError(404, "Not Found", '{"error":{"code":404}}')
      )
    ).toBe(true);
  });

  it("is false for rate limits, server errors, and non-Gmail errors", () => {
    expect(
      isGmailNotFoundError(new GmailApiError(429, "Too Many Requests", "{}"))
    ).toBe(false);
    expect(
      isGmailNotFoundError(new GmailApiError(500, "Internal Error", "{}"))
    ).toBe(false);
    expect(isGmailNotFoundError(new Error("404 somewhere in the text"))).toBe(
      false
    );
  });
});

describe("syncGmailMailboxIncremental — vanished threads", () => {
  let errorLog: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    errorLog = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
  });
  afterEach(() => vi.restoreAllMocks());

  it("drops a 404 thread instead of scheduling it for retry", async () => {
    // A 404 means the thread no longer exists in the mailbox (permanently
    // deleted, or a draft Gmail replaced). Re-fetching it can never succeed,
    // so it must not enter the pending-retry set.
    const { api } = mockApi({
      changes: [{ threadId: "gone" }, { threadId: "live" }],
      throwOn: new Map([
        ["gone", new GmailApiError(404, "Not Found", '{"error":{"code":404}}')],
      ]),
    });

    const result = await syncGmailMailboxIncremental(api, "100", [], 10);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(result.threads.map((t) => t.id)).toEqual(["live"]);
    expect(result.failedThreadIds).toEqual([]);
  });

  it("still retries a transient fetch failure", async () => {
    const { api } = mockApi({
      changes: [{ threadId: "flaky" }],
      throwOn: new Map([
        ["flaky", new GmailApiError(503, "Service Unavailable", "{}")],
      ]),
    });

    const result = await syncGmailMailboxIncremental(api, "100", [], 10);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(result.failedThreadIds).toEqual(["flaky"]);
  });

  it("does not log a vanished thread at error level", async () => {
    const { api } = mockApi({
      changes: [{ threadId: "gone" }],
      throwOn: new Map([["gone", new GmailApiError(404, "Not Found", "{}")]]),
    });

    await syncGmailMailboxIncremental(api, "100", [], 10);

    expect(errorLog).not.toHaveBeenCalled();
  });

  it("logs a genuine fetch failure at error level", async () => {
    const { api } = mockApi({
      changes: [{ threadId: "flaky" }],
      throwOn: new Map([["flaky", new GmailApiError(503, "Unavailable", "{}")]]),
    });

    await syncGmailMailboxIncremental(api, "100", [], 10);

    expect(errorLog).toHaveBeenCalledOnce();
    expect(String(errorLog.mock.calls[0][0])).toContain("flaky");
  });
});

describe("syncGmailMailboxIncremental — draft churn", () => {
  it("does not fetch threads whose only change is a draft message", async () => {
    // Gmail replaces the draft message on every autosave and purges it on
    // discard, so a draft's thread id is often already gone by the time we
    // walk history. Drafts aren't synced as notes either, so skip the fetch.
    const { api, getThread } = mockApi({
      changes: [
        { threadId: "draft", labelIds: ["DRAFT"] },
        { threadId: "mail", labelIds: ["INBOX", "UNREAD"] },
      ],
    });

    const result = await syncGmailMailboxIncremental(api, "100", [], 10);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["mail"]);
    // Skipped, not deferred — it must not come back on a later pass.
    expect(result.deferredThreadIds).toEqual([]);
    expect(result.failedThreadIds).toEqual([]);
  });

  it("fetches draft threads when drafts are being synced", async () => {
    const { api, getThread } = mockApi({
      changes: [{ threadId: "draft", labelIds: ["DRAFT"] }],
    });

    await syncGmailMailboxIncremental(api, "100", [], 10, {
      includeDrafts: true,
    });

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["draft"]);
  });

  it("still fetches a thread whose draft message changed labels", async () => {
    // Label changes (starring, archiving) are the user acting on a thread, so
    // they stay in scope even when the carrying message is a draft.
    const { api, getThread } = mockApi({
      changes: [
        { threadId: "starred", labelIds: ["DRAFT", "STARRED"], via: "labelsAdded" },
      ],
    });

    await syncGmailMailboxIncremental(api, "100", [], 10);

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["starred"]);
  });

  it("retries a previously-failed draft thread that was handed back in", async () => {
    // retryThreadIds come from our own pending set, not from history, so the
    // draft filter must not silently discard them.
    const { api, getThread } = mockApi({ changes: [] });

    await syncGmailMailboxIncremental(api, "100", ["pending"], 10);

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["pending"]);
  });
});

/** Minimal GmailSyncHost over an in-memory store. */
function makeHost(opts: {
  enabledChannels: string[];
  incremental: IncrementalState;
}): { host: GmailSyncHost; store: Map<string, unknown> } {
  const store = new Map<string, unknown>([
    ["enabled_channels", opts.enabledChannels],
    ["incremental_state", opts.incremental],
  ]);
  const host = {
    id: "twist-instance-1",
    get: vi.fn(async (key: string) => (store.has(key) ? store.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      store.set(key, value);
    }),
    setMany: vi.fn(async (entries: [string, unknown][]) => {
      for (const [key, value] of entries) store.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      store.delete(key);
    }),
    tools: {
      integrations: {
        get: vi.fn(async () => ({ token: "tok", scopes: [] })),
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
    },
  } as unknown as GmailSyncHost;
  return { host, store };
}

/** Stubs GmailApi so history reports one draft change and one inbox change. */
function stubDraftAndMailHistory() {
  vi.spyOn(GmailApi.prototype, "getHistory").mockResolvedValue({
    history: [
      {
        id: "hist-1",
        messagesAdded: [
          { message: { id: "m-draft", threadId: "draft", labelIds: ["DRAFT"] } },
        ],
      },
      {
        id: "hist-2",
        messagesAdded: [
          { message: { id: "m-mail", threadId: "mail", labelIds: ["INBOX"] } },
        ],
      },
    ],
    historyId: "999",
  } as any);
  return vi
    .spyOn(GmailApi.prototype, "getThread")
    .mockImplementation(
      async (id: string) =>
        ({ id, historyId: "h", messages: [] }) as unknown as GmailThread
    );
}

describe("draft filtering is driven by the enabled channels", () => {
  afterEach(() => vi.restoreAllMocks());

  it("incrementalSyncBatchFn skips drafts when Draft is not enabled", async () => {
    const getThread = stubDraftAndMailHistory();
    const { host } = makeHost({
      enabledChannels: ["INBOX"],
      incremental: { historyId: "100" },
    });

    await incrementalSyncBatchFn(host);

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["mail"]);
  });

  it("incrementalSyncBatchFn fetches drafts when Draft is enabled", async () => {
    const getThread = stubDraftAndMailHistory();
    const { host } = makeHost({
      enabledChannels: ["INBOX", "DRAFT"],
      incremental: { historyId: "100" },
    });

    await incrementalSyncBatchFn(host);

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["draft", "mail"]);
  });

  it("clears a vanished thread out of the persisted retry set", async () => {
    // The whole point of the classification: a thread that 404s must leave the
    // pending set on the first pass instead of riding the retry ladder for
    // MAX_THREAD_FETCH_ATTEMPTS more passes and ending in a "may be lost" log.
    vi.spyOn(GmailApi.prototype, "getHistory").mockResolvedValue({
      history: [],
      historyId: "999",
    } as any);
    vi.spyOn(GmailApi.prototype, "getThread").mockRejectedValue(
      new GmailApiError(404, "Not Found", '{"error":{"code":404}}')
    );
    vi.spyOn(console, "log").mockImplementation(() => {});
    const { host, store } = makeHost({
      enabledChannels: ["INBOX"],
      incremental: { historyId: "100", pendingThreadIds: [{ id: "gone", attempts: 2 }] },
    });

    await incrementalSyncBatchFn(host);

    const saved = store.get("incremental_state") as IncrementalState;
    expect(saved.pendingThreadIds).toEqual([]);
  });

  it("selfHealCheckFn skips drafts when Draft is not enabled", async () => {
    const getThread = stubDraftAndMailHistory();
    vi.spyOn(console, "log").mockImplementation(() => {});
    const { host } = makeHost({
      enabledChannels: ["INBOX"],
      incremental: { historyId: "100" },
    });

    await selfHealCheckFn(host);

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["mail"]);
  });
});
