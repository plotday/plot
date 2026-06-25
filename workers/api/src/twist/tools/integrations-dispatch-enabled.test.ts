import { describe, it, expect, vi } from "vitest";
import { Integrations } from "./integrations";

function makeHost(enabled: Record<string, boolean>) {
  return {
    sourceProvider: "google",
    buildSyncContext: vi.fn().mockResolvedValue({ recovering: false }),
    buildOnChannelEnabledEntry: (Integrations.prototype as any).buildOnChannelEnabledEntry,
    store: {
      get: async (key: string) => {
        const id = key.replace("channel_config:google:", "");
        return enabled[id] ? { enabled: true, title: id } : { enabled: false, title: id };
      },
    },
    dispatchEnabledChannels: (Integrations.prototype as any).dispatchEnabledChannels,
  } as any;
}

describe("dispatchEnabledChannels", () => {
  it("emits a non-recovery onChannelEnabled dispatch per still-enabled channel", async () => {
    const host = makeHost({ "mail:INBOX": true, "calendar:primary": true });
    const out = await host.dispatchEnabledChannels.call(host, "google", "actor-1", ["mail:INBOX", "calendar:primary"]);
    expect(out.__dispatch).toHaveLength(2);
    expect(out.__dispatch[0]).toMatchObject({ sourceMethod: "onChannelEnabled" });
    expect(out.__dispatch[0].args[1]).toEqual({ recovering: false });
    expect(host.buildSyncContext).toHaveBeenCalledWith({});
  });

  it("skips channels that are no longer enabled and returns undefined when none remain", async () => {
    const host = makeHost({ "mail:INBOX": false });
    expect(await host.dispatchEnabledChannels.call(host, "google", "actor-1", ["mail:INBOX"])).toBeUndefined();
  });

  it("filters disabled channels within a single call", async () => {
    const host = makeHost({ "mail:INBOX": true, "calendar:primary": false });
    const out = await host.dispatchEnabledChannels.call(host, "google", "actor-1", ["mail:INBOX", "calendar:primary"]);
    expect(out.__dispatch).toHaveLength(1);
    expect(out.__dispatch[0]).toMatchObject({ sourceMethod: "onChannelEnabled" });
    expect(out.__dispatch[0].args[0].id).toBe("mail:INBOX");
  });
});
