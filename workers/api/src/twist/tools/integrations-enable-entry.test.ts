import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

const call = (host: any, ...args: any[]) =>
  (Integrations.prototype as any).buildOnChannelEnabledEntry.call(host, ...args);

describe("buildOnChannelEnabledEntry", () => {
  const channel = { id: "mail:INBOX", title: "Inbox" };
  const ctx = { recovering: false };

  it("source provider → sourceMethod entry with onFailure", () => {
    const entry = call({ sourceProvider: "google" }, "google", channel, ctx);
    expect(entry).toEqual({
      sourceMethod: "onChannelEnabled",
      args: [{ id: "mail:INBOX", title: "Inbox" }, ctx],
      onFailure: { functionName: "__failChannelSync", args: ["google", "mail:INBOX"] },
    });
  });

  it("legacy provider → optionPath entry", () => {
    const host = { sourceProvider: null, providerConfigs: [{ provider: "google" }] };
    const entry = call(host, "google", channel, ctx);
    expect(entry.optionPath).toEqual(["providers", 0, "onChannelEnabled"]);
    expect(entry.args).toEqual([{ id: "mail:INBOX", title: "Inbox" }, ctx]);
    expect(entry.onFailure).toEqual({ functionName: "__failChannelSync", args: ["google", "mail:INBOX"] });
  });

  it("no matching provider → null", () => {
    const host = { sourceProvider: null, providerConfigs: [] };
    expect(call(host, "google", channel, ctx)).toBeNull();
  });
});
