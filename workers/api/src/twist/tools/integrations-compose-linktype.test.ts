import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// Unit tests for Integrations.resolveComposeLinkType — the create_link path's
// resolution of a draft type's LinkTypeConfig (and thus its compose.targets),
// which gates whether picked contacts are pre-resolved into connector
// recipients. The regression it guards: a combined Google connection declares
// its `email` config only on channel rows (dynamicLinkTypes, no
// sourceProvider.linkTypes), and a Gmail compose target is connection-scoped
// so the draft carries no channelId. The old lookup queried a single channel by
// channel_id (null → no row) and fell back to an undefined sourceProvider list,
// yielding undefined config → recipient resolution skipped → onCreateLink saw
// zero recipients.

const CONNECTOR = "connector-instance-id";

const EMAIL_CONFIG = {
  type: "email",
  label: "Thread",
  compose: { targets: "addresses" },
} as const;

/** Kysely stub whose channel `.execute()` returns `channelRows`. */
function mockDb(channelRows: unknown[]) {
  const chain: any = {
    selectFrom: () => chain,
    select: () => chain,
    where: () => chain,
    execute: async () => channelRows,
  };
  return chain;
}

function makeThis(channelRows: unknown[], sourceProvider: any) {
  return {
    sourceProvider,
    twistInstanceId: CONNECTOR,
    db: mockDb(channelRows),
    resolveComposeLinkType: (Integrations.prototype as any).resolveComposeLinkType,
  } as any;
}

const call = (self: any, type: string, channelId: string | null) =>
  (Integrations.prototype as any).resolveComposeLinkType.call(self, type, channelId);

describe("Integrations.resolveComposeLinkType", () => {
  it("resolves a dynamic-link-type config from channel rows when the draft has no channelId (combined Google / Gmail)", async () => {
    // Combined Google: no connector-level linkTypes; email config lives on the
    // mail:* channel rows; some channels declare nothing.
    const self = makeThis(
      [
        { channel_id: "INBOX", link_types: [] },
        { channel_id: "mail:SENT", link_types: [EMAIL_CONFIG] },
        { channel_id: "calendar:x", link_types: [{ type: "event" }] },
      ],
      { provider: "google" }, // linkTypes undefined (dynamicLinkTypes)
    );
    const cfg = await call(self, "email", null);
    expect(cfg?.compose?.targets).toBe("addresses");
  });

  it("prefers the draft's named channel's declared config", async () => {
    const self = makeThis(
      [
        { channel_id: "C1", link_types: [{ type: "issue", compose: { targets: "channels" } }] },
        { channel_id: "C2", link_types: [{ type: "issue", compose: { targets: "contacts" } }] },
      ],
      { provider: "slack" },
    );
    const cfg = await call(self, "issue", "C2");
    expect(cfg?.compose?.targets).toBe("contacts");
  });

  it("parses stringified channel link_types", async () => {
    const self = makeThis(
      [{ channel_id: "mail:SENT", link_types: JSON.stringify([EMAIL_CONFIG]) }],
      { provider: "google" },
    );
    const cfg = await call(self, "email", null);
    expect(cfg?.compose?.targets).toBe("addresses");
  });

  it("falls back to the connector-level sourceProvider.linkTypes when no channel declares the type", async () => {
    const self = makeThis(
      [{ channel_id: "C1", link_types: [] }],
      { provider: "linear", linkTypes: [{ type: "issue", compose: { targets: "channels" } }] },
    );
    const cfg = await call(self, "issue", null);
    expect(cfg?.compose?.targets).toBe("channels");
  });

  it("returns undefined when the type is declared nowhere", async () => {
    const self = makeThis([{ channel_id: "C1", link_types: [] }], { provider: "google" });
    const cfg = await call(self, "email", null);
    expect(cfg).toBeUndefined();
  });
});
