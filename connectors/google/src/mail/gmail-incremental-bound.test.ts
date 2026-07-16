import { afterEach, describe, expect, it, vi } from "vitest";

import {
  GmailApi,
  type GmailThread,
  MAX_HISTORY_PAGES_PER_PASS,
  syncGmailMailboxIncremental,
} from "./gmail-api";
import {
  type GmailSyncHost,
  type IncrementalState,
  MAX_INCREMENTAL_THREADS_PER_BATCH,
  MAX_THREAD_FETCH_ATTEMPTS,
  incrementalSyncBatchFn,
  mergePendingThreads,
} from "./sync";

/** Build a minimal GmailApi mock exposing only the methods the incremental
 *  sync touches (getHistory + getThread). */
function mockApi(opts: {
  changedThreadIds: string[];
  newHistoryId: string;
  failOn?: Set<string>;
}): { api: GmailApi; getThread: ReturnType<typeof vi.fn> } {
  const getThread = vi.fn(async (id: string): Promise<GmailThread> => {
    if (opts.failOn?.has(id)) throw new Error(`boom ${id}`);
    return { id, historyId: "h", messages: [] } as unknown as GmailThread;
  });
  const getHistory = vi.fn(async () => ({
    history: opts.changedThreadIds.map((id) => ({
      id: `hist-${id}`,
      messagesAdded: [{ message: { id: `m-${id}`, threadId: id } }],
    })),
    historyId: opts.newHistoryId,
  }));
  const api = { getHistory, getThread } as unknown as GmailApi;
  return { api, getThread };
}

describe("syncGmailMailboxIncremental — per-pass bound", () => {
  it("fetches at most maxThreads and defers the rest", async () => {
    const ids = ["t1", "t2", "t3", "t4", "t5"];
    const { api, getThread } = mockApi({
      changedThreadIds: ids,
      newHistoryId: "200",
    });

    const result = await syncGmailMailboxIncremental(api, "100", [], 2);

    expect("expired" in result && result.expired).toBe(false);
    if ("expired" in result && result.expired) return;

    // Only the cap is fetched into memory this pass.
    expect(getThread).toHaveBeenCalledTimes(2);
    expect(result.threads.map((t) => t.id)).toEqual(["t1", "t2"]);
    // The overflow is deferred, not fetched and not failed.
    expect(result.deferredThreadIds).toEqual(["t3", "t4", "t5"]);
    expect(result.failedThreadIds).toEqual([]);
    expect(result.historyId).toBe("200");
  });

  it("processes prior retry (deferred) ids ahead of newly-changed ones", async () => {
    // retryThreadIds are inserted first, so they fall within the cap before
    // freshly-changed threads — prior backlog drains first.
    const { api, getThread } = mockApi({
      changedThreadIds: ["new1", "new2"],
      newHistoryId: "201",
    });

    const result = await syncGmailMailboxIncremental(
      api,
      "100",
      ["retryA", "retryB"],
      2
    );
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(getThread.mock.calls.map((c) => c[0])).toEqual(["retryA", "retryB"]);
    expect(result.deferredThreadIds).toEqual(["new1", "new2"]);
  });

  it("does not bound when maxThreads is omitted (back-compat)", async () => {
    const ids = ["a", "b", "c"];
    const { api, getThread } = mockApi({
      changedThreadIds: ids,
      newHistoryId: "300",
    });
    const result = await syncGmailMailboxIncremental(api, "100", []);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(getThread).toHaveBeenCalledTimes(3);
    expect(result.deferredThreadIds).toEqual([]);
  });
});

/** Multi-page GmailApi mock: getHistory serves `pages` in order, keyed by the
 *  incoming pageToken; getThread returns a stub thread. */
function mockPagedApi(
  pages: {
    entries: { recordId: string; threadId: string }[];
    nextPageToken?: string;
  }[],
  mailboxHistoryId: string
): { api: GmailApi; getHistory: ReturnType<typeof vi.fn> } {
  const byToken = new Map<string | undefined, (typeof pages)[number]>();
  byToken.set(undefined, pages[0]);
  for (let i = 0; i < pages.length; i++) {
    const token = pages[i].nextPageToken;
    if (token !== undefined) byToken.set(token, pages[i + 1]);
  }
  const getHistory = vi.fn(
    async (_startHistoryId: string, _labelId?: string, pageToken?: string) => {
      const page = byToken.get(pageToken);
      if (!page) throw new Error(`unexpected pageToken ${pageToken}`);
      return {
        history: page.entries.map(({ recordId, threadId }) => ({
          id: recordId,
          messagesAdded: [{ message: { id: `m-${threadId}`, threadId } }],
        })),
        historyId: mailboxHistoryId,
        nextPageToken: page.nextPageToken,
      };
    }
  );
  const getThread = vi.fn(
    async (id: string): Promise<GmailThread> =>
      ({ id, historyId: "h", messages: [] }) as unknown as GmailThread
  );
  const api = { getHistory, getThread } as unknown as GmailApi;
  return { api, getHistory };
}

describe("syncGmailMailboxIncremental — history pagination", () => {
  it("walks every history page, not just the first", async () => {
    const { api, getHistory } = mockPagedApi(
      [
        {
          entries: [{ recordId: "101", threadId: "t1" }],
          nextPageToken: "page2",
        },
        {
          entries: [{ recordId: "102", threadId: "t2" }],
          nextPageToken: "page3",
        },
        { entries: [{ recordId: "103", threadId: "t3" }] },
      ],
      "999"
    );

    const result = await syncGmailMailboxIncremental(api, "100", [], 100);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(getHistory).toHaveBeenCalledTimes(3);
    // Changes from pages 2+ are collected (previously silently skipped).
    expect(result.threads.map((t) => t.id)).toEqual(["t1", "t2", "t3"]);
    // Fully drained → cursor advances to the mailbox-current history id.
    expect(result.historyId).toBe("999");
  });

  it("stops at the page cap and advances the cursor only to the last record read", async () => {
    // MAX_HISTORY_PAGES_PER_PASS pages each pointing at another page: the
    // walk must stop at the cap and the cursor must NOT jump to the
    // mailbox-current id (that would skip the unread tail).
    const pages = Array.from(
      { length: MAX_HISTORY_PAGES_PER_PASS + 2 },
      (_, i) => ({
        entries: [{ recordId: `rec-${i}`, threadId: `t${i}` }],
        nextPageToken:
          i < MAX_HISTORY_PAGES_PER_PASS + 1 ? `page-${i + 1}` : undefined,
      })
    );
    const { api, getHistory } = mockPagedApi(pages, "999");

    const result = await syncGmailMailboxIncremental(api, "100", [], 1000);
    if ("expired" in result && result.expired) throw new Error("unexpected");

    expect(getHistory).toHaveBeenCalledTimes(MAX_HISTORY_PAGES_PER_PASS);
    expect(result.historyId).toBe(`rec-${MAX_HISTORY_PAGES_PER_PASS - 1}`);
  });

  it("returns expired when a later page 404s", async () => {
    const { GmailApiError } = await import("./gmail-api");
    const getHistory = vi.fn(
      async (_h: string, _l?: string, pageToken?: string) => {
        if (pageToken === "page2") {
          throw new GmailApiError(404, "Not Found", "history expired");
        }
        return {
          history: [
            {
              id: "101",
              messagesAdded: [{ message: { id: "m-t1", threadId: "t1" } }],
            },
          ],
          historyId: "999",
          nextPageToken: "page2",
        };
      }
    );
    const api = {
      getHistory,
      getThread: vi.fn(),
    } as unknown as GmailApi;

    const result = await syncGmailMailboxIncremental(api, "100", [], 100);
    expect("expired" in result && result.expired).toBe(true);
  });
});

/** Minimal GmailSyncHost backed by an in-memory store, exposing spies for the
 *  scheduler continuation hook and the saved incremental cursor. */
function makeHost(initial: IncrementalState): {
  host: GmailSyncHost;
  store: Map<string, unknown>;
  queueIncrementalSync: ReturnType<typeof vi.fn>;
} {
  const store = new Map<string, unknown>([
    ["enabled_channels", ["INBOX"]],
    ["incremental_state", initial],
  ]);
  const queueIncrementalSync = vi.fn(async () => {});
  const host = {
    id: "twist-instance-1",
    get: vi.fn(async (key: string) =>
      store.has(key) ? store.get(key) : null
    ),
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
        // Threads in these tests carry no notes, so saveLink is never reached;
        // present only to satisfy the interface.
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
      queueIncrementalSync,
    },
  } as unknown as GmailSyncHost;
  return { host, store, queueIncrementalSync };
}

describe("incrementalSyncBatchFn — bounded pass + continuation", () => {
  afterEach(() => vi.restoreAllMocks());

  it("caps the pass, carries the overflow, and queues a continuation", async () => {
    const overflow = 5;
    const total = MAX_INCREMENTAL_THREADS_PER_BATCH + overflow;
    const ids = Array.from({ length: total }, (_, i) => `t${i}`);

    const getHistory = vi
      .spyOn(GmailApi.prototype, "getHistory")
      .mockResolvedValue({
        history: ids.map((id) => ({
          id: `hist-${id}`,
          messagesAdded: [{ message: { id: `m-${id}`, threadId: id } } as any],
        })),
        historyId: "999",
      } as any);
    const getThread = vi
      .spyOn(GmailApi.prototype, "getThread")
      .mockImplementation(
        async (id: string) =>
          ({ id, historyId: "h", messages: [] }) as unknown as GmailThread
      );

    const { host, store, queueIncrementalSync } = makeHost({
      historyId: "100",
    });

    await incrementalSyncBatchFn(host);

    expect(getHistory).toHaveBeenCalledTimes(1);
    // Only the cap is pulled into memory this pass — not all 25.
    expect(getThread).toHaveBeenCalledTimes(MAX_INCREMENTAL_THREADS_PER_BATCH);
    // The overflow is carried forward (attempts 0 — never attempted) and the
    // cursor advanced so we don't re-walk the window.
    const saved = store.get("incremental_state") as IncrementalState;
    expect(saved.historyId).toBe("999");
    expect(saved.pendingThreadIds).toHaveLength(overflow);
    expect(saved.pendingThreadIds?.every((p) => p.attempts === 0)).toBe(true);
    // A continuation is scheduled to drain the rest.
    expect(queueIncrementalSync).toHaveBeenCalledTimes(1);
  });

  it("does not queue a continuation when everything fits in one pass", async () => {
    const ids = ["a", "b"];
    vi.spyOn(GmailApi.prototype, "getHistory").mockResolvedValue({
      history: ids.map((id) => ({
        id: `hist-${id}`,
        messagesAdded: [{ message: { id: `m-${id}`, threadId: id } } as any],
      })),
      historyId: "201",
    } as any);
    vi.spyOn(GmailApi.prototype, "getThread").mockImplementation(
      async (id: string) =>
        ({ id, historyId: "h", messages: [] }) as unknown as GmailThread
    );

    const { host, store, queueIncrementalSync } = makeHost({ historyId: "100" });
    await incrementalSyncBatchFn(host);

    const saved = store.get("incremental_state") as IncrementalState;
    expect(saved.pendingThreadIds).toEqual([]);
    expect(queueIncrementalSync).not.toHaveBeenCalled();
  });
});

describe("mergePendingThreads — deferred carry", () => {
  it("carries deferred ids without bumping their attempt counter", () => {
    const prior = [{ id: "d1", attempts: 0 }];
    const merged = mergePendingThreads(prior, [], ["d1", "d2"]);
    // Neither deferred id is a fetch attempt, so attempts stay put — a large
    // backlog must not be abandoned just for waiting its turn.
    expect(merged).toEqual([
      { id: "d1", attempts: 0 },
      { id: "d2", attempts: 0 },
    ]);
  });

  it("still bumps and eventually drops genuinely-failed fetches", () => {
    const prior = [{ id: "f1", attempts: MAX_THREAD_FETCH_ATTEMPTS }];
    // f1 has exhausted its attempts → dropped; f2 is a fresh failure → kept@1.
    const merged = mergePendingThreads(prior, ["f1", "f2"], []);
    expect(merged).toEqual([{ id: "f2", attempts: 1 }]);
  });

  it("keeps failed and deferred sets distinct in one merge", () => {
    const merged = mergePendingThreads([], ["f1"], ["d1"]);
    expect(merged).toEqual([
      { id: "f1", attempts: 1 },
      { id: "d1", attempts: 0 },
    ]);
  });
});
