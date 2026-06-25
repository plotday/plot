import { describe, it, expect } from "vitest";
import type { Channel } from "@plotday/twister/tools/integrations";
import { Integrations } from "./integrations";

function makeHost() {
  const calls = { getChannelAccess: 0, buildSyncContext: 0, applied: [] as string[] };
  const tree: Channel[] = [
    { id: "mail:INBOX", title: "Inbox" } as Channel,
    { id: "calendar:primary", title: "Primary" } as Channel,
  ];
  return {
    calls,
    db: { selectFrom: () => ({ select: () => ({ where: () => ({ where: () => ({ limit: () => ({ executeTakeFirst: async () => undefined }) }) }) }) }) },
    getChannelAccess: async () => { calls.getChannelAccess++; return tree; },
    findChannelInTree: (Integrations.prototype as any).findChannelInTree,
    buildSyncContext: async () => { calls.buildSyncContext++; return { recovering: false }; },
    applyChannelEnabled: async (_p: any, _a: any, channel: Channel) => {
      calls.applied.push(channel.id);
      return { sourceMethod: "onChannelEnabled", args: [{ id: channel.id }, {}] };
    },
    enableSyncBatch: (Integrations.prototype as any).enableSyncBatch,
  } as any;
}

describe("enableSyncBatch", () => {
  it("reads the tree once, builds context once, applies each channel, returns one __dispatch", async () => {
    const host = makeHost();
    const out = await host.enableSyncBatch.call(host, "google", ["mail:INBOX", "calendar:primary"], "actor-1");
    expect(host.calls.getChannelAccess).toBe(1);
    expect(host.calls.buildSyncContext).toBe(1);
    expect(host.calls.applied).toEqual(["mail:INBOX", "calendar:primary"]);
    expect(out.__dispatch).toHaveLength(2);
  });

  it("returns undefined for an empty channel list", async () => {
    const host = makeHost();
    expect(await host.enableSyncBatch.call(host, "google", [], "actor-1")).toBeUndefined();
    expect(host.calls.getChannelAccess).toBe(0);
  });

  it("with { dispatch: false } persists channels but returns no __dispatch", async () => {
    const host = makeHost();
    const out = await host.enableSyncBatch.call(host, "google", ["mail:INBOX"], "actor-1", undefined, { dispatch: false });
    expect(host.calls.applied).toEqual(["mail:INBOX"]); // still persisted
    expect(out).toBeUndefined();
  });
});
