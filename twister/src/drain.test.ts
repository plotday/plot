import { describe, expect, it, vi } from "vitest";

import {
  DEFAULT_DRAIN_BATCH_SIZE,
  DEFAULT_DRAIN_MAX_ATTEMPTS,
  type DrainHost,
  cancelDrainImpl,
  drainBacklogImpl,
  scheduleDrainImpl,
} from "./drain";

type ScheduledTask = {
  key: string;
  callback: unknown;
  options: { runAt: Date; coalesce?: boolean };
};

/**
 * In-memory DrainHost. `callback()` records the wrapper's target args so a
 * test can "fire" the scheduled task by invoking drainBacklogImpl with them
 * (which is exactly what the task runtime does via __drainBacklog).
 */
function makeHost() {
  const map = new Map<string, unknown>();
  const scheduled: ScheduledTask[] = [];
  const createdCallbacks: unknown[][] = [];
  const drainChanges = vi.fn(async (_ids: string[]) => {});
  // Class methods carry their name; vi.fn() is named "spy", so restore the
  // name the by-name dispatch relies on.
  Object.defineProperty(drainChanges, "name", { value: "drainChanges" });

  const host = {
    drainChanges,
    callback: vi.fn(async (_fn: unknown, ...extraArgs: unknown[]) => {
      createdCallbacks.push(extraArgs);
      return `cb-${createdCallbacks.length}`;
    }),
    scheduleTask: vi.fn(
      async (
        key: string,
        callback: unknown,
        options: { runAt: Date; coalesce?: boolean }
      ) => {
        scheduled.push({ key, callback, options });
        return "cancel-token";
      }
    ),
    cancelScheduledTask: vi.fn(async () => {}),
    __drainBacklog: function stub() {},
    tools: {
      store: {
        get: vi.fn(async <T,>(k: string) =>
          map.has(k) ? (map.get(k) as T) : null
        ),
        set: vi.fn(async (k: string, v: unknown) => {
          map.set(k, v);
        }),
        setMany: vi.fn(async (entries: [string, unknown][]) => {
          for (const [k, v] of entries) map.set(k, v);
        }),
        clear: vi.fn(async (k: string) => {
          map.delete(k);
        }),
        list: vi.fn(async (p: string) =>
          [...map.keys()].filter((k) => k.startsWith(p))
        ),
      },
    },
  };

  /** Fire the most recently scheduled drain task, like the runtime would. */
  const fire = async () => {
    const last = createdCallbacks[createdCallbacks.length - 1];
    const [key, name, options] = last as [
      string,
      string,
      { batchSize: number; delayMs: number; maxAttempts: number },
    ];
    await drainBacklogImpl(host as unknown as DrainHost, key, name, options);
  };

  return { host: host as unknown as DrainHost, raw: host, map, scheduled, fire };
}

const pendingKeys = (map: Map<string, unknown>) =>
  [...map.keys()].filter((k) => k.startsWith("__drain__:")).sort();

describe("scheduleDrain", () => {
  it("persists ids as pending keys and schedules a coalescing keyed task", async () => {
    const { host, raw, map, scheduled } = makeHost();

    await scheduleDrainImpl(host, "sync", raw.drainChanges, {
      ids: ["a", "b"],
    });

    expect(pendingKeys(map)).toEqual([
      "__drain__:sync:a",
      "__drain__:sync:b",
    ]);
    expect(map.get("__drain__:sync:a")).toBe(0);
    expect(scheduled).toHaveLength(1);
    expect(scheduled[0].key).toBe("__drain__:sync");
    expect(scheduled[0].options.coalesce).toBe(true);
    expect(scheduled[0].options.runAt.getTime()).toBeGreaterThan(Date.now());
  });

  it("signal-only: schedules without writing any pending keys", async () => {
    const { host, raw, map, scheduled } = makeHost();

    await scheduleDrainImpl(host, "sync", raw.drainChanges);

    expect(pendingKeys(map)).toEqual([]);
    expect(scheduled).toHaveLength(1);
  });

  it("a burst of calls schedules under the same key with coalesce (one pending pass)", async () => {
    const { host, raw, scheduled } = makeHost();

    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["b"] });
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["c"] });

    // The platform's coalescing keyed task collapses these into one pending
    // pass; the SDK's job is to always use the same key + coalesce flag.
    expect(new Set(scheduled.map((t) => t.key))).toEqual(
      new Set(["__drain__:sync"])
    );
    expect(scheduled.every((t) => t.options.coalesce)).toBe(true);
  });

  it("rejects anonymous handlers", async () => {
    const { host } = makeHost();
    await expect(
      scheduleDrainImpl(host, "sync", async () => {})
    ).rejects.toThrow(/named method/);
  });

  it("rejects handlers that are not methods on the host", async () => {
    const { host } = makeHost();
    async function orphanHandler() {}
    await expect(
      scheduleDrainImpl(host, "sync", orphanHandler)
    ).rejects.toThrow(/not a method/);
  });
});

describe("drain pass (__drainBacklog)", () => {
  it("hands the handler a bounded slice, clears it, and schedules a continuation", async () => {
    const { host, raw, map, scheduled, fire } = makeHost();
    const total = DEFAULT_DRAIN_BATCH_SIZE + 5;
    const ids = Array.from({ length: total }, (_, i) =>
      `m${String(i).padStart(3, "0")}`
    );
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids });

    await fire();

    expect(raw.drainChanges).toHaveBeenCalledTimes(1);
    const slice = raw.drainChanges.mock.calls[0][0];
    expect(slice).toHaveLength(DEFAULT_DRAIN_BATCH_SIZE);
    // Processed ids released; overflow retained for the continuation.
    expect(pendingKeys(map)).toHaveLength(5);
    // Initial schedule + continuation, both coalesced under the same key.
    expect(scheduled).toHaveLength(2);
    expect(scheduled[1].key).toBe("__drain__:sync");
  });

  it("signal-only pass invokes the handler with [] and schedules no continuation", async () => {
    const { host, raw, scheduled, fire } = makeHost();
    await scheduleDrainImpl(host, "sync", raw.drainChanges);

    await fire();

    expect(raw.drainChanges).toHaveBeenCalledWith([]);
    expect(scheduled).toHaveLength(1); // no continuation
  });

  it("a failing pass keeps the ids, bumps attempts, and rethrows", async () => {
    const { host, raw, map, fire } = makeHost();
    raw.drainChanges.mockRejectedValueOnce(new Error("boom"));
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });

    await expect(fire()).rejects.toThrow("boom");

    expect(map.get("__drain__:sync:a")).toBe(1);
  });

  it("drops an id after exhausting maxAttempts", async () => {
    const { host, raw, map, fire } = makeHost();
    raw.drainChanges.mockRejectedValue(new Error("still broken"));
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });
    map.set("__drain__:sync:a", DEFAULT_DRAIN_MAX_ATTEMPTS);

    await expect(fire()).rejects.toThrow("still broken");

    // attempts would exceed the cap → dropped so the drain can't wedge.
    expect(pendingKeys(map)).toEqual([]);
  });

  it("re-marking an id already in the running slice is subsumed by that pass", async () => {
    const { host, raw, map, fire } = makeHost();
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });
    // The handler processes "a" while a fresh notification re-marks it: the
    // handler fetches live state, so the pass covers the change and the key
    // is released.
    raw.drainChanges.mockImplementationOnce(async () => {
      map.set("__drain__:sync:a", 0);
    });

    await fire();

    expect(pendingKeys(map)).toEqual([]);
  });

  it("ids marked during a pass (not in its slice) survive for the next pass", async () => {
    const { host, raw, map, fire } = makeHost();
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });
    raw.drainChanges.mockImplementationOnce(async () => {
      map.set("__drain__:sync:b", 0);
    });

    await fire();

    expect(pendingKeys(map)).toEqual(["__drain__:sync:b"]);
  });

  it("throws a descriptive error when the handler was renamed away", async () => {
    const { host, fire, raw } = makeHost();
    await scheduleDrainImpl(host, "sync", raw.drainChanges, { ids: ["a"] });
    delete (raw as Record<string, unknown>).drainChanges;

    await expect(fire()).rejects.toThrow(/no longer exists/);
  });
});

describe("cancelDrain", () => {
  it("cancels the scheduled task and discards pending ids", async () => {
    const { host, raw, map } = makeHost();
    await scheduleDrainImpl(host, "sync", raw.drainChanges, {
      ids: ["a", "b"],
    });

    await cancelDrainImpl(host, "sync");

    expect(raw.cancelScheduledTask).toHaveBeenCalledWith("__drain__:sync");
    expect(pendingKeys(map)).toEqual([]);
  });
});
