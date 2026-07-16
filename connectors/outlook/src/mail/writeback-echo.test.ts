import { describe, expect, it, vi } from "vitest";

// Swap only the GraphMailApi class so onThreadToDoFn talks to a mock Graph
// client; keep every other real export from the module intact.
const { graphApi } = vi.hoisted(() => ({
  graphApi: {
    getConversationMessages: vi.fn(),
    updateMessage: vi.fn(),
  },
}));

vi.mock("./graph-mail-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-mail-api")>();
  return { ...actual, GraphMailApi: vi.fn(() => graphApi) };
});

import { onThreadToDoFn } from "./sync";

/**
 * Regression guard for dropping `skip_todo_writeback`: the platform now
 * suppresses the onThreadToDo echo via write-source provenance
 * (setThreadToDo stamps it), so the connector no longer keeps a per-thread
 * echo guard. A stale key left over from a pre-cleanup deploy must NOT
 * short-circuit the write-back.
 */
describe("onThreadToDo — no skip_todo_writeback echo guard", () => {
  function makeHost(initial: Record<string, unknown> = {}) {
    const map = new Map<string, unknown>(Object.entries(initial));
    const store = {
      get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
      set: vi.fn(async (k: string, v: unknown) => {
        map.set(k, v);
      }),
      clear: vi.fn(async (k: string) => {
        map.delete(k);
      }),
      list: vi.fn(async (p: string) =>
        [...map.keys()].filter((k) => k.startsWith(p))
      ),
    };
    return {
      map,
      set: store.set,
      get: store.get,
      clear: store.clear,
      tools: {
        store,
        integrations: { get: vi.fn(async () => ({ token: "tok" })) },
      },
    };
  }

  it("flags the conversation even when a stale skip_todo_writeback key is present", async () => {
    graphApi.getConversationMessages.mockResolvedValue([
      { id: "m1", isDraft: false, flag: { flagStatus: "notFlagged" } },
    ]);
    graphApi.updateMessage.mockResolvedValue(undefined);

    const host = makeHost({ "skip_todo_writeback:conv-1": true });
    const thread = { meta: { conversationId: "conv-1", channelId: "C1" } };

    await onThreadToDoFn(host as never, thread as never, {} as never, true, {});

    // Write-back happened (guard did not short-circuit it).
    expect(graphApi.updateMessage).toHaveBeenCalledWith("m1", {
      flag: { flagStatus: "flagged" },
    });
    // The stale key is neither consulted nor cleared.
    expect(host.clear).not.toHaveBeenCalledWith("skip_todo_writeback:conv-1");
    // The dual-purpose flagged: baseline is still maintained.
    expect(host.set).toHaveBeenCalledWith("flagged:conv-1", true);
  });
});
