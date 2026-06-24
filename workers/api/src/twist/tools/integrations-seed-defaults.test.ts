import { describe, it, expect } from "vitest";
import type { Channel } from "@plotday/twister/tools/integrations";
import { Integrations, selectOwnedDefaultChannels } from "./integrations";

const ch = (id: string, enabledByDefault?: boolean, children?: Channel[]): Channel =>
  ({ id, title: id, enabledByDefault, children } as Channel);

describe("selectOwnedDefaultChannels", () => {
  it("returns only channels flagged enabledByDefault === true", () => {
    const out = selectOwnedDefaultChannels([
      ch("mail:INBOX", true),
      ch("mail:Label_42", false),
      ch("calendar:primary", true),
      ch("calendar:holidays"), // undefined → excluded
    ]);
    expect(out.map((c) => c.id)).toEqual(["mail:INBOX", "calendar:primary"]);
  });

  it("recurses into children (e.g. nested calendars/labels)", () => {
    const out = selectOwnedDefaultChannels([
      ch("group", undefined, [ch("calendar:primary", true), ch("calendar:shared", false)]),
    ]);
    expect(out.map((c) => c.id)).toEqual(["calendar:primary"]);
  });

  it("returns empty when none are owned-default", () => {
    expect(selectOwnedDefaultChannels([ch("mail:INBOX", false), ch("x")])).toEqual([]);
  });
});

// Table-aware Kysely stub. The flag read hits twist_instance_connection
// (executeTakeFirst → { seed_default_channels }); the "already enabled?" probe
// hits channel (executeTakeFirst → enabledRow or undefined). updateTable
// records the flag-clear.
function makeHost(opts: {
  seedFlag: boolean;
  hasEnabledChannel: boolean;
  enableCalls: Channel[];
  cleared: { value: boolean };
}) {
  const select = (table: string) => ({
    select: () => select(table),
    where: () => select(table),
    limit: () => select(table),
    executeTakeFirst: async () =>
      table === "twist_instance_connection"
        ? { user_id: "u", seed_default_channels: opts.seedFlag }
        : table === "channel"
        ? opts.hasEnabledChannel
          ? { channel_id: "x" }
          : undefined
        : undefined,
  });
  const update = () => ({
    set: (v: any) => {
      if (v.seed_default_channels === false) opts.cleared.value = true;
      return update();
    },
    where: () => update(),
    execute: async () => {},
  });
  return {
    twistInstanceId: "ti-1",
    db: { selectFrom: (t: string) => select(t), updateTable: () => update() },
    flattenChannels: (Integrations.prototype as any).flattenChannels,
    buildSyncContext: async () => ({}),
    applyChannelEnabled: async (_p: any, _a: any, channel: Channel) => {
      opts.enableCalls.push(channel);
      return { sourceMethod: "onChannelEnabled", args: [{ id: channel.id }, {}] };
    },
    seedDefaultChannelsIfFlagged: (Integrations.prototype as any)
      .seedDefaultChannelsIfFlagged,
  } as any;
}

describe("seedDefaultChannelsIfFlagged", () => {
  const channels = [ch("mail:INBOX", true), ch("mail:Label_42", false), ch("calendar:primary", true)];

  it("flag set + no enabled channels → enables owned defaults, clears flag", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: true, hasEnabledChannel: false, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls.map((c) => c.id)).toEqual(["mail:INBOX", "calendar:primary"]);
    expect(dispatches).toHaveLength(2);
    expect(cleared.value).toBe(true);
  });

  it("flag set + already has an enabled channel → no enables (defensive), still clears flag", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: true, hasEnabledChannel: true, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls).toEqual([]);
    expect(dispatches).toEqual([]);
    expect(cleared.value).toBe(true);
  });

  it("flag unset → no-op, no flag write", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: false, hasEnabledChannel: false, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls).toEqual([]);
    expect(dispatches).toEqual([]);
    expect(cleared.value).toBe(false);
  });
});
