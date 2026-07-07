import { describe, expect, it, vi } from "vitest";
import {
  OutlookMail,
  pickChannelForConversation,
} from "./outlook-mail";
import type { GraphMessage, WellKnownFolders } from "./graph-mail-api";

const inFolder = (parentFolderId: string): GraphMessage =>
  ({ id: `m-${parentFolderId}`, parentFolderId }) as GraphMessage;
const wk: WellKnownFolders = {
  inbox: "f-inbox",
  sentitems: "f-sent",
  archive: "f-arch",
};

describe("pickChannelForConversation", () => {
  it("prefers enabled custom folders over inbox", () => {
    expect(
      pickChannelForConversation(
        [inFolder("f-custom"), inFolder("f-inbox")],
        new Set(["f-inbox", "f-custom"]),
        wk
      )
    ).toBe("f-custom");
  });
  it("falls back inbox → sentitems", () => {
    expect(
      pickChannelForConversation(
        [inFolder("f-sent")],
        new Set(["f-inbox", "f-sent"]),
        wk
      )
    ).toBe("f-sent");
    expect(
      pickChannelForConversation(
        [inFolder("f-inbox"), inFolder("f-sent")],
        new Set(["f-inbox", "f-sent"]),
        wk
      )
    ).toBe("f-inbox");
  });
  it("returns null when nothing matches", () => {
    expect(
      pickChannelForConversation([inFolder("f-other")], new Set(["f-inbox"]), wk)
    ).toBeNull();
  });
});

describe("recoverMailboxDelivery — durable recovery on upgrade", () => {
  function setup(entries: Array<[string, unknown]>) {
    const storeMap = new Map<string, unknown>(entries);
    const store = {
      get: vi.fn(async (k: string) =>
        storeMap.has(k) ? storeMap.get(k) : null
      ),
      set: vi.fn(async (k: string, v: unknown) => {
        storeMap.set(k, v);
      }),
      clear: vi.fn(async (k: string) => {
        storeMap.delete(k);
      }),
      list: vi.fn(async (p: string) =>
        [...storeMap.keys()].filter((k) => k.startsWith(p))
      ),
    };
    const tools = { store, integrations: {}, network: {}, files: {} };
    const outlook = new OutlookMail(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    const spies = {
      setupMailboxSubscription: vi
        .spyOn(outlook, "setupMailboxSubscription")
        .mockResolvedValue(undefined),
      scheduleSelfHealCheck: vi
        .spyOn(outlook, "scheduleSelfHealCheck")
        .mockResolvedValue(undefined),
      scheduleMailboxRenewal: vi
        .spyOn(outlook, "scheduleMailboxRenewal")
        .mockResolvedValue(undefined),
      requeueInitialSync: vi
        .spyOn(outlook, "requeueInitialSync")
        .mockResolvedValue(undefined),
    };
    return { outlook, spies };
  }

  const subscription = (expiration: Date) => ({
    subscriptionId: "sub-1",
    clientState: "secret",
    webhookUrl: "https://example.com/hook",
    expiration,
    created: "2026-01-01T00:00:00.000Z",
  });
  const FUTURE = new Date(Date.now() + 2 * 24 * 60 * 60 * 1000);
  const PAST = new Date(Date.now() - 60 * 60 * 1000);

  it("stranded (no mailbox_subscription): re-establishes and backfills every enabled folder", async () => {
    const { outlook, spies } = setup([["enabled_channels", ["f-inbox", "f-sent"]]]);
    await outlook.recoverMailboxDelivery();
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("f-inbox");
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("f-sent");
    expect(spies.setupMailboxSubscription).toHaveBeenCalledTimes(1);
    expect(spies.scheduleSelfHealCheck).not.toHaveBeenCalled();
  });

  it("expired subscription: treated as stranded — re-establishes and backfills", async () => {
    const { outlook, spies } = setup([
      ["enabled_channels", ["f-inbox"]],
      ["mailbox_subscription", subscription(PAST)],
    ]);
    await outlook.recoverMailboxDelivery();
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("f-inbox");
    expect(spies.setupMailboxSubscription).toHaveBeenCalledTimes(1);
    expect(spies.scheduleMailboxRenewal).not.toHaveBeenCalled();
  });

  it("healthy subscription: only re-asserts recurring tasks (no re-setup, no backfill)", async () => {
    const { outlook, spies } = setup([
      ["enabled_channels", ["f-inbox"]],
      ["mailbox_subscription", subscription(FUTURE)],
    ]);
    await outlook.recoverMailboxDelivery();
    expect(spies.scheduleSelfHealCheck).toHaveBeenCalledTimes(1);
    expect(spies.scheduleMailboxRenewal).toHaveBeenCalledTimes(1);
    expect(spies.setupMailboxSubscription).not.toHaveBeenCalled();
    expect(spies.requeueInitialSync).not.toHaveBeenCalled();
  });

  it("no enabled channels: does nothing", async () => {
    const { outlook, spies } = setup([["enabled_channels", []]]);
    await outlook.recoverMailboxDelivery();
    expect(spies.setupMailboxSubscription).not.toHaveBeenCalled();
    expect(spies.scheduleSelfHealCheck).not.toHaveBeenCalled();
    expect(spies.requeueInitialSync).not.toHaveBeenCalled();
  });
});

describe("queueIncrementalSync — coalesced scheduling", () => {
  it("persists notified ids and schedules a keyed coalescing drain instead of enqueueing per notification", async () => {
    const map = new Map<string, unknown>();
    const store = {
      get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
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
    };
    const scheduleTask = vi.fn(async () => "cancel-token");
    const runTask = vi.fn(async () => {});
    const tools = {
      store,
      callbacks: { create: vi.fn(async () => "cb-token") },
      tasks: { scheduleTask, runTask },
      integrations: {},
      network: {},
      files: {},
    };
    const connector = new OutlookMail(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ) as any;

    await connector.queueIncrementalSync(["m1", "m2"]);

    // One Graph notification per message must NOT become one queued task per
    // notification: the platform drain records the ids durably and schedules
    // one coalesced pass per burst.
    expect(map.get("__drain__:mailbox-incremental-sync:m1")).toBe(0);
    expect(map.get("__drain__:mailbox-incremental-sync:m2")).toBe(0);
    expect(runTask).not.toHaveBeenCalled();
    expect(scheduleTask).toHaveBeenCalledTimes(1);
    const [key, , options] = scheduleTask.mock.calls[0] as unknown as [
      string,
      unknown,
      { runAt: Date; coalesce?: boolean },
    ];
    expect(key).toBe("__drain__:mailbox-incremental-sync");
    expect(options.coalesce).toBe(true);
    expect(options.runAt.getTime()).toBeGreaterThan(Date.now());
  });
});
