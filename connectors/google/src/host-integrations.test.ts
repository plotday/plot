import { describe, expect, it, vi } from "vitest";

import { withNamespacedChannelIds } from "./host-integrations";

function mockIntegrations() {
  return {
    get: vi.fn(async () => ({ token: "t", scopes: [] as string[] })),
    saveLink: vi.fn(async () => null),
    saveLinks: vi.fn(async () => {}),
    channelSyncCompleted: vi.fn(async () => {}),
    archiveLinks: vi.fn(async () => {}),
  };
}

// Minimal NewLinkWithNotes-shaped stub; the wrapper only touches channelId.
function link(channelId: string | null) {
  return { channelId, source: "s", type: "event" } as never;
}

describe("withNamespacedChannelIds", () => {
  it("namespaces link.channelId on saveLink", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "tasks");
    await wrapped.saveLink(link("list1"));
    expect(inner.saveLink).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "tasks:list1" })
    );
  });

  it("namespaces every link on saveLinks", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.saveLinks([link("kris@plot.day"), link("team@plot.day")]);
    expect(inner.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ channelId: "calendar:kris@plot.day" }),
      expect.objectContaining({ channelId: "calendar:team@plot.day" }),
    ]);
  });

  it("does not double-namespace an already-namespaced id", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.saveLink(link("calendar:cal1"));
    expect(inner.saveLink).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "calendar:cal1" })
    );
  });

  it("namespaces a raw id that itself contains a colon", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.saveLink(link("foo:bar"));
    expect(inner.saveLink).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "calendar:foo:bar" })
    );
  });

  it("leaves a null channelId alone", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.saveLink(link(null));
    expect(inner.saveLink).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: null })
    );
  });

  it("archives BOTH data eras when filtering by channelId", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.archiveLinks({ channelId: "cal1", type: "event" });
    expect(inner.archiveLinks).toHaveBeenCalledWith({
      channelId: "calendar:cal1",
      type: "event",
    });
    expect(inner.archiveLinks).toHaveBeenCalledWith({
      channelId: "cal1",
      type: "event",
    });
  });

  it("passes archiveLinks filters without channelId through once, unchanged", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.archiveLinks({ meta: { threadId: "x" } });
    expect(inner.archiveLinks).toHaveBeenCalledTimes(1);
    expect(inner.archiveLinks).toHaveBeenCalledWith({ meta: { threadId: "x" } });
  });

  it("passes token reads and sync-completed signals through untouched", async () => {
    const inner = mockIntegrations();
    const wrapped = withNamespacedChannelIds(inner, "calendar");
    await wrapped.get("cal1");
    await wrapped.channelSyncCompleted("cal1");
    expect(inner.get).toHaveBeenCalledWith("cal1");
    expect(inner.channelSyncCompleted).toHaveBeenCalledWith("cal1");
  });
});
