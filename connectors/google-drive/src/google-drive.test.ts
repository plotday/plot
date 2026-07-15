import { beforeEach, describe, expect, it } from "vitest";

import { GoogleDrive } from "./google-drive";

/**
 * Build a GoogleDrive wired to in-memory store/task fakes so the watch-renewal
 * scheduling can be exercised without a live runtime. The connector's
 * `this.get/callback/scheduleTask` helpers delegate to these fakes via
 * `this.tools`, so nothing in the connector is stubbed.
 */
function makeDrive() {
  const store = new Map<string, unknown>();
  const scheduledRecurring: Array<{
    key: string;
    intervalMs: number;
    firstRunAt?: Date;
  }> = [];
  const cancelled: string[] = [];
  const ranUnkeyed: Array<{ runAt?: Date }> = [];

  const tools = {
    store: {
      get: async (k: string) => (store.has(k) ? store.get(k) : null),
      set: async (k: string, v: unknown) => void store.set(k, v),
      clear: async (k: string) => void store.delete(k),
      list: async () => [],
    },
    callbacks: { create: async () => "callback-token" },
    tasks: {
      // The durable keyed-singleton primitive the connector should now use
      // for the renewal (see scheduleWatchRenewal).
      scheduleRecurring: async (
        key: string,
        _cb: unknown,
        opts: { intervalMs: number; firstRunAt?: Date }
      ) => void scheduledRecurring.push({ key, ...opts }),
      cancelScheduledTask: async (key: string) => void cancelled.push(key),
      // The un-keyed primitive the connector should NOT use for renewals.
      runTask: async (_cb: unknown, opts?: { runAt?: Date }) => {
        ranUnkeyed.push({ runAt: opts?.runAt });
        return "unkeyed-token";
      },
    },
  };

  const drive = new GoogleDrive(
    "00000000-0000-0000-0000-000000000000" as never,
    { getTools: () => tools, waitForReady: async () => {} } as never
  );

  return {
    store,
    scheduledRecurring,
    cancelled,
    ranUnkeyed,
    scheduleRenewal: (folderId: string): Promise<void> =>
      (drive as unknown as {
        scheduleWatchRenewal(id: string): Promise<void>;
      }).scheduleWatchRenewal(folderId),
  };
}

describe("google-drive watch renewal", () => {
  let drive: ReturnType<typeof makeDrive>;

  beforeEach(() => {
    drive = makeDrive();
    drive.store.set("drive_watch_folder1", {
      expiry: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
    });
  });

  it("schedules the renewal as a keyed singleton task (not a bare runTask)", async () => {
    await drive.scheduleRenewal("folder1");

    expect(drive.scheduledRecurring).toHaveLength(1);
    expect(drive.scheduledRecurring[0].key).toBe("watch-renewal:folder1");
    // Must NOT use the un-keyed runTask, which is what leaked parallel chains.
    expect(drive.ranUnkeyed).toHaveLength(0);
  });

  it("re-scheduling reuses the same key, so the runtime replaces (no leak)", async () => {
    await drive.scheduleRenewal("folder1");
    await drive.scheduleRenewal("folder1");

    expect(drive.scheduledRecurring.map((s) => s.key)).toEqual([
      "watch-renewal:folder1",
      "watch-renewal:folder1",
    ]);
  });
});
