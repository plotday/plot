import { describe, it, expect, vi } from "vitest";

import { textToADF, adfToText } from "./jira-adf";
import { statusCategoryToIcon, Jira } from "./jira";

describe("ADF round-trip", () => {
  for (const s of ["hello", "para one\n\npara two", "line", "a\n\nb\n\nc"]) {
    it(`round-trips ${JSON.stringify(s)}`, () => {
      expect(adfToText(textToADF(s))).toBe(s.trim());
    });
  }

  it("textToADF makes one paragraph per blank-line block", () => {
    expect(textToADF("a\n\nb").content).toHaveLength(2);
  });

  it("textToADF trims surrounding whitespace before splitting", () => {
    // Leading/trailing blank lines must not add empty paragraphs, so the
    // round-trip baseline equals `s.trim()`.
    expect(adfToText(textToADF("  \n\nhello\n\n  "))).toBe("hello");
  });

  it("adfToText returns '' for empty / non-object input", () => {
    expect(adfToText(null)).toBe("");
    expect(adfToText(undefined)).toBe("");
    expect(adfToText("plain string")).toBe("");
  });

  it("textToADF produces a valid empty doc for empty text", () => {
    const doc = textToADF("");
    expect(doc.type).toBe("doc");
    expect(doc.version).toBe(1);
    expect(doc.content).toHaveLength(0);
  });

  it("adfToText joins multiple paragraphs with a blank line", () => {
    const doc = {
      version: 1,
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "first" }] },
        { type: "paragraph", content: [{ type: "text", text: "second" }] },
      ],
    };
    expect(adfToText(doc)).toBe("first\n\nsecond");
  });
});

describe("statusCategoryToIcon", () => {
  it("maps status categories to icons", () => {
    expect(statusCategoryToIcon("new")).toBe("todo");
    expect(statusCategoryToIcon("indeterminate")).toBe("inProgress");
    expect(statusCategoryToIcon("done")).toBe("done");
  });

  it("defaults unknown / missing categories to todo", () => {
    expect(statusCategoryToIcon("anything-else")).toBe("todo");
    expect(statusCategoryToIcon(undefined)).toBe("todo");
    expect(statusCategoryToIcon(null)).toBe("todo");
  });
});

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => void map.set(key, value)),
    clear: vi.fn(async (key: string) => void map.delete(key)),
  };
}

function makeJira(
  opts: {
    store?: ReturnType<typeof makeStore>;
    integrations?: Record<string, unknown>;
  } = {}
): Jira {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi
        .fn()
        .mockResolvedValue({ token: "tok", provider: { cloud_id: "cloud-1" } }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    tasks: { runTask: vi.fn().mockResolvedValue(undefined) },
  };
  return new Jira("twist-1" as never, { getTools: () => tools } as never);
}

const projectId = "10001";

type SearchIssuesResult = { issues: unknown[]; total: number };

function makeSearchClient(result: SearchIssuesResult) {
  return {
    issueSearch: {
      searchForIssuesUsingJql: vi.fn().mockResolvedValue(result),
    },
  };
}

describe("syncBatch", () => {
  it("signals channelSyncCompleted when the last page is reached (initial sync)", async () => {
    const store = makeStore({
      [`sync_state_${projectId}`]: {
        startAt: 0,
        batchNumber: 1,
        issuesProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const jira = makeJira({ store, integrations: { channelSyncCompleted } });
    (jira as unknown as { getClient: unknown }).getClient = vi
      .fn()
      .mockResolvedValue(makeSearchClient({ issues: [], total: 0 }));

    await (
      jira as unknown as {
        syncBatch: (id: string, options?: unknown) => Promise<void>;
      }
    ).syncBatch(projectId);

    expect(channelSyncCompleted).toHaveBeenCalledWith(projectId);
    // sync state is cleared once the chain has nothing left to schedule
    expect(store.map.has(`sync_state_${projectId}`)).toBe(false);
  });

  it("does not signal channelSyncCompleted while more pages remain", async () => {
    const store = makeStore({
      [`sync_state_${projectId}`]: {
        startAt: 0,
        batchNumber: 1,
        issuesProcessed: 0,
        initialSync: true,
      },
    });
    const channelSyncCompleted = vi.fn();
    const jira = makeJira({ store, integrations: { channelSyncCompleted } });
    (jira as unknown as { getClient: unknown }).getClient = vi
      .fn()
      .mockResolvedValue(makeSearchClient({ issues: [], total: 1000 }));
    (jira as unknown as { callback: unknown }).callback = vi
      .fn()
      .mockResolvedValue("cb");

    await (
      jira as unknown as {
        syncBatch: (id: string, options?: unknown) => Promise<void>;
      }
    ).syncBatch(projectId);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    const state = store.map.get(`sync_state_${projectId}`) as {
      startAt: number;
    };
    expect(state.startAt).toBe(50);
  });

  it("does not signal channelSyncCompleted when an incremental (non-initial) sync completes", async () => {
    const store = makeStore({
      [`sync_state_${projectId}`]: {
        startAt: 0,
        batchNumber: 1,
        issuesProcessed: 0,
        initialSync: false,
      },
    });
    const channelSyncCompleted = vi.fn();
    const jira = makeJira({ store, integrations: { channelSyncCompleted } });
    (jira as unknown as { getClient: unknown }).getClient = vi
      .fn()
      .mockResolvedValue(makeSearchClient({ issues: [], total: 0 }));

    await (
      jira as unknown as {
        syncBatch: (id: string, options?: unknown) => Promise<void>;
      }
    ).syncBatch(projectId);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    // sync state is still cleared even though we don't signal completion
    expect(store.map.has(`sync_state_${projectId}`)).toBe(false);
  });
});
