import { afterEach, describe, expect, it, vi } from "vitest";

import {
  type GmailApi,
  type GmailThread,
  mapWithConcurrency,
  syncGmailChannel,
  syncGmailMailboxIncremental,
} from "./gmail-api";
import {
  type GmailSyncHost,
  type InitialSyncState,
  initialSyncBatchFn,
} from "./sync";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

// ---------------------------------------------------------------------------
// mapWithConcurrency
// ---------------------------------------------------------------------------

describe("mapWithConcurrency", () => {
  it("preserves input order even when later items resolve first", async () => {
    const resolveOrder: string[] = [];
    const result = await mapWithConcurrency(["a", "b", "c", "d"], 4, async (id, i) => {
      // Later items resolve sooner.
      await new Promise((r) => setTimeout(r, (4 - i) * 5));
      resolveOrder.push(id);
      return id.toUpperCase();
    });
    expect(result).toEqual(["A", "B", "C", "D"]);
    expect(resolveOrder).not.toEqual(["a", "b", "c", "d"]);
  });

  it("never runs more than `limit` mappers at once", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    await mapWithConcurrency(Array.from({ length: 12 }, (_, i) => i), 5, async (n) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
      return n;
    });
    expect(maxInFlight).toBe(5);
  });

  it("propagates mapper rejections", async () => {
    await expect(
      mapWithConcurrency([1, 2, 3], 2, async (n) => {
        if (n === 2) throw new Error("boom");
        return n;
      })
    ).rejects.toThrow("boom");
  });
});

// ---------------------------------------------------------------------------
// Full-sync history floor (`after:` bound)
// ---------------------------------------------------------------------------

/** Mock exposing the two methods the full-sync path touches. */
function mockFullSyncApi(): {
  api: GmailApi;
  getThreads: ReturnType<typeof vi.fn>;
  getThread: ReturnType<typeof vi.fn>;
} {
  const getThreads = vi.fn(async () => ({
    threads: [
      { id: "t1", historyId: "h1" },
      { id: "t2", historyId: "h2" },
    ],
    nextPageToken: "page-2",
    resultSizeEstimate: 2,
  }));
  const getThread = vi.fn(
    async (id: string): Promise<GmailThread> =>
      ({ id, historyId: `h-${id}`, messages: [] }) as unknown as GmailThread
  );
  const api = { getThreads, getThread } as unknown as GmailApi;
  return { api, getThreads, getThread };
}

describe("syncGmailChannel full pass — history floor", () => {
  const floor = new Date("2026-06-29T00:00:00Z");
  const floorEpoch = Math.floor(floor.getTime() / 1000);

  it("bounds a label backfill with an after: query when historyFloor is set", async () => {
    const { api, getThreads } = mockFullSyncApi();
    const result = await syncGmailChannel(
      api,
      { channelId: "INBOX", historyFloor: floor },
      20
    );

    expect(getThreads).toHaveBeenCalledWith(
      "INBOX",
      undefined,
      20,
      `after:${floorEpoch}`
    );
    // The floor survives into the persisted cursor for the next batch.
    expect(result.state.historyFloor).toEqual(floor);
  });

  it("combines the floor with a search channel's own query", async () => {
    const { api, getThreads } = mockFullSyncApi();
    await syncGmailChannel(
      api,
      { channelId: "search:from:alerts@example.com", historyFloor: floor },
      20
    );

    expect(getThreads).toHaveBeenCalledWith(
      "INBOX",
      undefined,
      20,
      `from:alerts@example.com after:${floorEpoch}`
    );
  });

  it("revives a floor that round-tripped storage as an ISO string", async () => {
    const { api, getThreads } = mockFullSyncApi();
    await syncGmailChannel(
      api,
      {
        channelId: "INBOX",
        historyFloor: floor.toISOString() as unknown as Date,
      },
      20
    );
    expect(getThreads).toHaveBeenCalledWith(
      "INBOX",
      undefined,
      20,
      `after:${floorEpoch}`
    );
  });

  it("leaves the query unset when no floor is present (back-compat)", async () => {
    const { api, getThreads } = mockFullSyncApi();
    await syncGmailChannel(api, { channelId: "INBOX" }, 20);
    expect(getThreads).toHaveBeenCalledWith("INBOX", undefined, 20, undefined);
  });
});

// ---------------------------------------------------------------------------
// Parallel thread fetches keep list order and failure semantics
// ---------------------------------------------------------------------------

describe("parallel thread fetching", () => {
  it("full pass returns threads in listing order despite out-of-order resolution", async () => {
    const { api, getThreads, getThread } = mockFullSyncApi();
    getThreads.mockResolvedValueOnce({
      threads: [
        { id: "t1", historyId: "h1" },
        { id: "t2", historyId: "h2" },
        { id: "t3", historyId: "h3" },
      ],
      nextPageToken: undefined,
      resultSizeEstimate: 3,
    });
    getThread.mockImplementation(async (id: string) => {
      const delay = { t1: 15, t2: 5, t3: 10 }[id] ?? 0;
      await new Promise((r) => setTimeout(r, delay));
      return { id, historyId: `h-${id}`, messages: [] } as unknown as GmailThread;
    });

    const result = await syncGmailChannel(api, { channelId: "INBOX" }, 20);
    expect(result.threads.map((t) => t.id)).toEqual(["t1", "t2", "t3"]);
  });

  it("full pass skips threads whose fetch fails and keeps the rest", async () => {
    const { api, getThreads, getThread } = mockFullSyncApi();
    getThreads.mockResolvedValueOnce({
      threads: [
        { id: "t1", historyId: "h1" },
        { id: "t2", historyId: "h2" },
        { id: "t3", historyId: "h3" },
      ],
      nextPageToken: undefined,
      resultSizeEstimate: 3,
    });
    getThread.mockImplementation(async (id: string) => {
      if (id === "t2") throw new Error("boom t2");
      return { id, historyId: `h-${id}`, messages: [] } as unknown as GmailThread;
    });

    const result = await syncGmailChannel(api, { channelId: "INBOX" }, 20);
    expect(result.threads.map((t) => t.id)).toEqual(["t1", "t3"]);
  });

  it("incremental pass records failed fetches without dropping the others", async () => {
    const getThread = vi.fn(async (id: string) => {
      if (id === "b") throw new Error("boom b");
      return { id, historyId: "h", messages: [] } as unknown as GmailThread;
    });
    const getHistory = vi.fn(async () => ({
      history: ["a", "b", "c"].map((id) => ({
        id: `hist-${id}`,
        messagesAdded: [{ message: { id: `m-${id}`, threadId: id } }],
      })),
      historyId: "500",
    }));
    const api = { getHistory, getThread } as unknown as GmailApi;

    const result = await syncGmailMailboxIncremental(api, "100", [], 20);
    if ("expired" in result && result.expired) throw new Error("unexpected");
    expect(result.threads.map((t) => t.id)).toEqual(["a", "c"]);
    expect(result.failedThreadIds).toEqual(["b"]);
  });
});

// ---------------------------------------------------------------------------
// initialSyncBatchFn persists the floor across batches
// ---------------------------------------------------------------------------

function makeBatchHost(initialState: InitialSyncState): {
  host: GmailSyncHost;
  store: Map<string, unknown>;
} {
  const store = new Map<string, unknown>([
    ["enabled_channels", ["INBOX"]],
    ["initial_state_INBOX", initialState],
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
      store: {
        acquireLock: vi.fn(async () => true),
        releaseLock: vi.fn(async () => {}),
        list: vi.fn(async () => []),
      },
    },
  } as unknown as GmailSyncHost;
  return { host, store };
}

describe("initialSyncBatchFn — history floor persistence", () => {
  it("carries historyFloor into the next batch's cursor and the Gmail query", async () => {
    const floor = new Date("2026-06-29T00:00:00Z");
    const { host, store } = makeBatchHost({ historyFloor: floor });

    const seenUrls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        seenUrls.push(url);
        if (url.includes("/threads/")) {
          return new Response(
            JSON.stringify({ id: "t1", historyId: "h1", messages: [] }),
            { status: 200 }
          );
        }
        return new Response(
          JSON.stringify({
            threads: [{ id: "t1", historyId: "h1" }],
            nextPageToken: "page-2",
            resultSizeEstimate: 1,
          }),
          { status: 200 }
        );
      })
    );

    const result = await initialSyncBatchFn(host, "INBOX", 1);

    expect(result).toEqual({ next: { batchNumber: 2 } });
    const listUrl = seenUrls.find((u) => u.includes("/threads?"));
    expect(listUrl).toContain(
      `q=after%3A${Math.floor(floor.getTime() / 1000)}`
    );
    const nextCursor = store.get("initial_state_INBOX") as InitialSyncState;
    expect(new Date(nextCursor.historyFloor as unknown as string)).toEqual(
      floor
    );
  });
});
