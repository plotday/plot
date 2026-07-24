import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the Google Tasks REST client so listTasks / updateTask can be driven to
// throw a deleted-list 404 without any network I/O. The real GoogleTasksApiError
// class is kept (partial mock) so the production not-found check matches.
vi.mock("./api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./api")>();
  return {
    ...actual,
    listTasks: vi.fn(),
    updateTask: vi.fn(),
    createTask: vi.fn(),
  };
});

import { GoogleTasksApiError } from "./api";
import * as api from "./api";
import {
  syncBatchFn,
  periodicSyncBatchFn,
  onLinkUpdatedFn,
  onCreateLinkFn,
  transformTask,
  type SyncState,
  type PeriodicSyncState,
  type TasksSyncHost,
} from "./sync";

const LIST_ID = "deleted-list-123";

const NOT_FOUND_BODY = JSON.stringify({
  error: {
    code: 404,
    message: "Task list not found.",
    errors: [{ message: "Task list not found.", domain: "global", reason: "notFound" }],
  },
});

// `tasks.insert` (create) is inconsistent with the other list-scoped
// endpoints: instead of a 404 it returns this 400 shape for a deleted/invalid
// list id.
const INVALID_LIST_BODY = JSON.stringify({
  error: {
    code: 400,
    message: "Invalid task list ID",
    errors: [{ message: "Invalid task list ID", domain: "global", reason: "invalid" }],
  },
});

type HostHarness = {
  host: TasksSyncHost;
  store: Map<string, unknown>;
  archiveLinks: ReturnType<typeof vi.fn>;
  cancelScheduledTask: ReturnType<typeof vi.fn>;
  saveLink: ReturnType<typeof vi.fn>;
};

function makeHost(): HostHarness {
  const store = new Map<string, unknown>();
  const archiveLinks = vi.fn(async () => {});
  const cancelScheduledTask = vi.fn(async () => {});
  const saveLink = vi.fn(async () => "thread-id");

  const host: TasksSyncHost = {
    id: "twist-instance-1",
    set: async (key, value) => {
      store.set(key, value);
    },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    get: async <T>(key: string) => (store.has(key) ? (store.get(key) as T) : null),
    clear: async (key) => {
      store.delete(key);
    },
    tools: {
      integrations: {
        get: async () => ({ token: "tok", scopes: [] }),
        saveLink,
        channelSyncCompleted: vi.fn(async () => {}),
        archiveLinks,
      },
    },
    scheduler: {
      queueSyncBatch: vi.fn(async () => {}),
      queuePeriodicSyncBatch: vi.fn(async () => {}),
      schedulePeriodicSync: vi.fn(async () => {}),
      cancelScheduledTask,
    },
  };

  return { host, store, archiveLinks, cancelScheduledTask, saveLink };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("syncBatchFn — deleted task list (404)", () => {
  it("tears the channel down instead of throwing", async () => {
    const { host, store, archiveLinks, cancelScheduledTask } = makeHost();
    store.set(`sync_enabled_${LIST_ID}`, true);
    store.set(`sync_state_${LIST_ID}`, {
      pageToken: null,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    vi.mocked(api.listTasks).mockRejectedValue(
      new GoogleTasksApiError(404, NOT_FOUND_BODY)
    );

    const result = await syncBatchFn(host, LIST_ID);

    expect(result).toEqual({ done: true });
    // Poll cancelled, links archived, per-channel state cleared.
    expect(cancelScheduledTask).toHaveBeenCalledWith(`poll:${LIST_ID}`);
    expect(archiveLinks).toHaveBeenCalledWith({ channelId: LIST_ID });
    expect(store.has(`sync_state_${LIST_ID}`)).toBe(false);
    expect(store.has(`sync_enabled_${LIST_ID}`)).toBe(false);
  });

  it("still throws on a non-404 (genuine) failure", async () => {
    const { host, store } = makeHost();
    store.set(`sync_state_${LIST_ID}`, {
      pageToken: null,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    vi.mocked(api.listTasks).mockRejectedValue(
      new GoogleTasksApiError(500, "Internal Server Error")
    );

    await expect(syncBatchFn(host, LIST_ID)).rejects.toThrow(/500/);
  });
});

describe("periodicSyncBatchFn — deleted task list (404)", () => {
  it("tears the channel down instead of throwing", async () => {
    const { host, store, archiveLinks, cancelScheduledTask } = makeHost();
    store.set(`sync_enabled_${LIST_ID}`, true);
    store.set(`periodic_sync_state_${LIST_ID}`, {
      pageToken: null,
      cycleStart: "2026-06-25T00:00:00.000Z",
    } satisfies PeriodicSyncState);

    vi.mocked(api.listTasks).mockRejectedValue(
      new GoogleTasksApiError(404, NOT_FOUND_BODY)
    );

    const result = await periodicSyncBatchFn(host, LIST_ID);

    expect(result).toEqual({ done: true });
    expect(cancelScheduledTask).toHaveBeenCalledWith(`poll:${LIST_ID}`);
    expect(archiveLinks).toHaveBeenCalledWith({ channelId: LIST_ID });
  });
});

describe("onLinkUpdatedFn — deleted task/list (404)", () => {
  it("swallows the 404 instead of throwing", async () => {
    const { host } = makeHost();
    vi.mocked(api.updateTask).mockRejectedValue(
      new GoogleTasksApiError(404, NOT_FOUND_BODY)
    );

    await expect(
      onLinkUpdatedFn(host, {
        status: "done",
        meta: { taskId: "t1", listId: LIST_ID },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
    ).resolves.toBeUndefined();
  });

  it("still throws on a non-404 failure", async () => {
    const { host } = makeHost();
    vi.mocked(api.updateTask).mockRejectedValue(
      new GoogleTasksApiError(500, "Internal Server Error")
    );

    await expect(
      onLinkUpdatedFn(host, {
        status: "done",
        meta: { taskId: "t1", listId: LIST_ID },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
    ).rejects.toThrow(/500/);
  });
});

describe("onCreateLinkFn — deleted/invalid task list on create (400)", () => {
  it("aborts (returns null) instead of throwing when the list is gone", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockRejectedValue(
      new GoogleTasksApiError(400, INVALID_LIST_BODY)
    );

    const result = await onCreateLinkFn(host, {
      type: "task",
      channelId: LIST_ID,
      title: "Buy milk",
      status: "open",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result).toBeNull();
  });

  it("still throws on a non-matching 400 (genuine validation failure)", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockRejectedValue(
      new GoogleTasksApiError(
        400,
        JSON.stringify({ error: { code: 400, message: "Invalid due date" } })
      )
    );

    await expect(
      onCreateLinkFn(host, {
        type: "task",
        channelId: LIST_ID,
        title: "Buy milk",
        status: "open",
        noteContent: null,
        contacts: [],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
    ).rejects.toThrow(/Invalid due date/);
  });

  it("still throws on a non-404/400 (genuine) failure", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockRejectedValue(
      new GoogleTasksApiError(500, "Internal Server Error")
    );

    await expect(
      onCreateLinkFn(host, {
        type: "task",
        channelId: LIST_ID,
        title: "Buy milk",
        status: "open",
        noteContent: null,
        contacts: [],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
    ).rejects.toThrow(/500/);
  });

  it("returns the created task link on success", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockResolvedValue({
      id: "task-99",
      title: "Buy milk",
      status: "needsAction",
      updated: "2026-07-24T00:00:00.000Z",
      position: "0001",
      selfLink: "https://tasks.googleapis.com/tasks/v1/task-99",
    });

    const result = await onCreateLinkFn(host, {
      type: "task",
      channelId: LIST_ID,
      title: "Buy milk",
      status: "open",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result?.source).toBe("google-tasks:task:task-99");
    expect(result?.channelId).toBe(LIST_ID);
  });
});

describe("onCreateLinkFn — to-do default on create", () => {
  it("marks the created task as to-do when created open", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockResolvedValue({
      id: "task-100",
      title: "Buy milk",
      status: "needsAction",
      updated: "2026-07-24T00:00:00.000Z",
      position: "0001",
      selfLink: "https://tasks.googleapis.com/tasks/v1/task-100",
    });

    const result = await onCreateLinkFn(host, {
      type: "task",
      channelId: LIST_ID,
      title: "Buy milk",
      status: "open",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result?.todo).toBe(true);
  });

  it("does not mark the created task as to-do when composed as done", async () => {
    const { host } = makeHost();

    vi.mocked(api.createTask).mockResolvedValue({
      id: "task-101",
      title: "Buy milk",
      status: "needsAction",
      updated: "2026-07-24T00:00:00.000Z",
      position: "0001",
      selfLink: "https://tasks.googleapis.com/tasks/v1/task-101",
    });

    const result = await onCreateLinkFn(host, {
      type: "task",
      channelId: LIST_ID,
      title: "Buy milk",
      status: "done",
      noteContent: null,
      contacts: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any);

    expect(result?.todo).toBeUndefined();
  });
});

describe("transformTask — to-do mapping (no link schedules)", () => {
  const baseTask = {
    id: "task-1",
    title: "Buy milk",
    status: "needsAction" as const,
    updated: "2026-07-01T12:00:00.000Z",
    position: "0001",
    selfLink: "https://tasks.googleapis.com/tasks/v1/task-1",
  };

  it("maps an open task with a due date to todo + todoDate", () => {
    const link = transformTask(
      { ...baseTask, due: "2026-07-15T00:00:00.000Z" },
      LIST_ID,
      false,
      [],
      null
    );
    expect(link.todo).toBe(true);
    expect(link.todoDate).toBe("2026-07-15");
    // Tasks must never carry link schedules: those are shared,
    // calendar-event-shaped, and would render the task in the agenda.
    expect(link.schedules).toBeUndefined();
  });

  it("maps an open task without a due date to todo (Now bucket)", () => {
    const link = transformTask(baseTask, LIST_ID, false, [], null);
    expect(link.todo).toBe(true);
    expect(link.todoDate).toBeUndefined();
    expect(link.schedules).toBeUndefined();
  });

  it("leaves to-do state untouched for completed tasks (done status handles it)", () => {
    const link = transformTask(
      { ...baseTask, status: "completed", due: "2026-07-15T00:00:00.000Z" },
      LIST_ID,
      false,
      [],
      null
    );
    expect(link.status).toBe("done");
    expect(link.todo).toBeUndefined();
    expect(link.todoDate).toBeUndefined();
    expect(link.schedules).toBeUndefined();
  });

  it("attributes the thread and description note to the connection owner", () => {
    const authActorId = "actor-owner" as unknown as Parameters<typeof transformTask>[4];
    const link = transformTask(
      { ...baseTask, notes: "remember the oat milk" },
      LIST_ID,
      false,
      [],
      authActorId
    );
    // Thread author = owner, not the connector.
    expect(link.author).toEqual({ id: authActorId });
    const desc = (link.notes ?? []).find(
      (n) => (n as { key?: string }).key === "description"
    ) as { author?: unknown } | undefined;
    expect(desc?.author).toEqual({ id: authActorId });
  });

  it("declares an authorless thread (null) when the owner actor is unknown", () => {
    const link = transformTask(
      { ...baseTask, notes: "body" },
      LIST_ID,
      false,
      [],
      null
    );
    expect(link.author).toBeNull();
  });
});
