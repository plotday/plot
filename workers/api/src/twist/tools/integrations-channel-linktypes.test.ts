import { describe, it, expect } from "vitest";
import type { Channel } from "@plotday/twister/tools/integrations";
import { Integrations } from "./integrations";

// A connector-level link type carrying a `compose` block, as declared at the
// class level by source connectors (LinkedIn/Instagram/WhatsApp) that return
// channels WITHOUT per-channel linkTypes from getChannels().
const CONNECTOR_LINK_TYPES = [
  {
    type: "conversation",
    label: "LinkedIn conversation",
    compose: { targets: "contacts", status: "inbox" },
  },
];

// A channel-level link type, as attached per-channel by dynamic connectors
// (e.g. the Google composite) in getChannels().
const CHANNEL_LINK_TYPES = [
  { type: "email", label: "Gmail email", compose: { targets: "addresses" } },
];

/**
 * Capturing Kysely stub for `insertInto("channel")`. Records the `.values()`
 * payload (object for applyChannelEnabled, array for mirrorChannelsToDb) and
 * swallows the `.onConflict()` callback without invoking it.
 */
function captureInsert() {
  const captured: { values?: any } = {};
  const db = {
    insertInto: (_table: string) => ({
      values: (v: any) => {
        captured.values = v;
        return {
          onConflict: (_fn: any) => ({ execute: async () => {} }),
          execute: async () => {},
        };
      },
    }),
  };
  return { db, captured };
}

describe("applyChannelEnabled — channel.link_types fallback (#1a)", () => {
  function host(sourceProvider: any, providerConfigs: any[] = []) {
    const { db, captured } = captureInsert();
    const h = {
      twistInstanceId: "ti-1",
      sourceProvider,
      providerConfigs,
      store: { set: async () => {} },
      db,
      markChannelSyncStarted: async () => {},
      connectorLinkTypes: (Integrations.prototype as any).connectorLinkTypes,
      applyChannelEnabled: (Integrations.prototype as any).applyChannelEnabled,
    } as any;
    return { h, captured };
  }

  it("persists connector-level linkTypes when the channel declares none", async () => {
    const { h, captured } = host({
      provider: "linkedin",
      linkTypes: CONNECTOR_LINK_TYPES,
    });
    // observeOnly=true skips markChannelSyncStarted; the DB write still runs.
    await h.applyChannelEnabled.call(
      h,
      "linkedin",
      "actor-1",
      { id: "li-1", title: "LinkedIn" } as Channel,
      {},
      true
    );
    expect(captured.values?.link_types).toBeTruthy();
    expect(JSON.parse(captured.values.link_types)).toEqual(CONNECTOR_LINK_TYPES);
  });

  it("prefers the channel's own linkTypes over the connector fallback", async () => {
    const { h, captured } = host({
      provider: "google",
      linkTypes: CONNECTOR_LINK_TYPES,
    });
    await h.applyChannelEnabled.call(
      h,
      "google",
      "actor-1",
      { id: "INBOX", title: "Inbox", linkTypes: CHANNEL_LINK_TYPES } as Channel,
      {},
      true
    );
    expect(JSON.parse(captured.values.link_types)).toEqual(CHANNEL_LINK_TYPES);
  });

  it("writes null when neither channel nor connector declares linkTypes", async () => {
    const { h, captured } = host(null);
    await h.applyChannelEnabled.call(
      h,
      "slack",
      "actor-1",
      { id: "C1", title: "general" } as Channel,
      {},
      true
    );
    expect(captured.values.link_types).toBeNull();
  });
});

describe("mirrorChannelsToDb — channel.link_types fallback (#1a)", () => {
  it("persists connector-level linkTypes for channels that declare none", async () => {
    const { db, captured } = captureInsert();
    const h = {
      twistInstanceId: "ti-1",
      sourceProvider: { provider: "linkedin", linkTypes: CONNECTOR_LINK_TYPES },
      providerConfigs: [],
      db,
      flattenChannels: (Integrations.prototype as any).flattenChannels,
      connectorLinkTypes: (Integrations.prototype as any).connectorLinkTypes,
      mirrorChannelsToDb: (Integrations.prototype as any).mirrorChannelsToDb,
    } as any;
    await h.mirrorChannelsToDb.call(h, [{ id: "li-1", title: "LinkedIn" }]);
    const row = (captured.values as any[])[0];
    expect(JSON.parse(row.link_types)).toEqual(CONNECTOR_LINK_TYPES);
  });
});

describe("Integrations internal-Plot options — forwards sourceProvider (#1b)", () => {
  it("includes sourceProvider so addContacts/saveLink can write CEA bindings", () => {
    const h = {
      twistInstanceId: "ti-1",
      db: {} as any,
      env: {} as any,
      sourceProvider: { provider: "linkedin", linkTypes: CONNECTOR_LINK_TYPES },
      internalPlotOptions: (Integrations.prototype as any).internalPlotOptions,
    } as any;
    const opts = h.internalPlotOptions.call(h);
    expect(opts.sourceProvider?.provider).toBe("linkedin");
  });
});
