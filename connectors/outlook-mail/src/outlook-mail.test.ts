import { describe, expect, it, vi } from "vitest";
import {
  OutlookMail,
  pickChannelForConversation,
  recipientsFor,
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

describe("recipientsFor", () => {
  it("excludes self always", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: ["a@b.com", "me@b.com"],
        self: "ME@b.com",
      })
    ).toEqual(["a@b.com"]);
  });
  it("empty constraint set sends to nobody (private note)", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(),
        candidates: ["a@b.com"],
        self: "me@b.com",
      })
    ).toEqual([]);
  });
  it("constraint filters to allowed", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(["a@b.com"]),
        candidates: ["a@b.com", "c@d.com"],
        self: "me@b.com",
      })
    ).toEqual(["a@b.com"]);
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
