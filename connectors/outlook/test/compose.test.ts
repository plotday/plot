import { describe, it, expect, vi } from "vitest";
import type { AuthToken, Channel, LinkTypeConfig } from "@plotday/twister/tools/integrations";
import type { Product } from "../src/products/product";
import { composeChannels, resolveProductForChannelId, resolveProductForLinkType } from "../src/compose";

// ---------------------------------------------------------------------------
// Fake product helpers
// ---------------------------------------------------------------------------

function makeToken(scopes: string[]): AuthToken {
  return {
    accessToken: "fake-access-token",
    scopes,
  } as unknown as AuthToken;
}

const EVENT_LINK_TYPE: LinkTypeConfig = {
  type: "event",
  label: "Event",
  statuses: [],
  includesSchedules: true,
};

const EMAIL_LINK_TYPE: LinkTypeConfig = {
  type: "email",
  label: "Email",
  statuses: [],
};

const CONTACTS_LINK_TYPE: LinkTypeConfig = {
  type: "contact",
  label: "Contact",
  statuses: [],
};

const calendarFake: Product = {
  key: "calendar",
  requiredScopes: ["cal.events"],
  linkTypes: [EVENT_LINK_TYPE],
  getRawChannels: async (_token) => [
    { id: "primary", title: "My Calendar" },
    { id: "work@example.com", title: "Work" },
  ],
  onEnable: vi.fn(),
  onDisable: vi.fn(),
};

const mailFake: Product = {
  key: "mail",
  requiredScopes: ["mail.modify"],
  linkTypes: [EMAIL_LINK_TYPE],
  getRawChannels: async (_token) => [
    { id: "INBOX", title: "Inbox" },
  ],
  onEnable: vi.fn(),
  onDisable: vi.fn(),
};

const contactsFake: Product = {
  key: "contacts",
  requiredScopes: ["contacts.read"],
  linkTypes: [CONTACTS_LINK_TYPE],
  getRawChannels: async (_token) => [
    { id: "contacts", title: "Contacts" },
  ],
  onEnable: vi.fn(),
  onDisable: vi.fn(),
};

// ---------------------------------------------------------------------------
// composeChannels
// ---------------------------------------------------------------------------

describe("composeChannels", () => {
  it("excludes a product whose required scope is absent from token.scopes", async () => {
    // Give only 'mail.modify', not 'cal.events' — calendar should not appear
    const token = makeToken(["mail.modify"]);
    const channels = await composeChannels([calendarFake, mailFake], token);

    const ids = channels.map((c) => c.id);
    expect(ids).not.toContain("calendar:primary");
    expect(ids).not.toContain("calendar:work@example.com");
    expect(ids).toContain("mail:INBOX");
  });

  it("includes a product whose required scopes are present", async () => {
    const token = makeToken(["cal.events", "mail.modify"]);
    const channels = await composeChannels([calendarFake, mailFake], token);

    expect(channels.some((c) => c.id === "calendar:primary")).toBe(true);
    expect(channels.some((c) => c.id === "calendar:work@example.com")).toBe(true);
    expect(channels.some((c) => c.id === "mail:INBOX")).toBe(true);
  });

  it("prefixes channel ids with '<productKey>:'", async () => {
    const token = makeToken(["cal.events"]);
    const channels = await composeChannels([calendarFake], token);

    for (const ch of channels) {
      expect(ch.id.startsWith("calendar:")).toBe(true);
    }
  });

  it("leaves title un-prefixed", async () => {
    const token = makeToken(["cal.events"]);
    const channels = await composeChannels([calendarFake], token);

    const primary = channels.find((c) => c.id === "calendar:primary");
    expect(primary?.title).toBe("My Calendar");
  });

  it("attaches the product's linkTypes to each channel", async () => {
    const token = makeToken(["cal.events"]);
    const channels = await composeChannels([calendarFake], token);

    for (const ch of channels) {
      expect(ch.linkTypes).toEqual([EVENT_LINK_TYPE]);
    }
  });

  it("prefixes children ids recursively", async () => {
    const parentRaw: Channel = {
      id: "parent",
      title: "Parent",
      children: [
        { id: "child1", title: "Child 1" },
        { id: "child2:nested", title: "Child 2 Nested" },
      ],
    };
    const productWithChildren: Product = {
      key: "calendar",
      requiredScopes: [],
      linkTypes: [EVENT_LINK_TYPE],
      getRawChannels: async () => [parentRaw],
      onEnable: vi.fn(),
      onDisable: vi.fn(),
    };

    const token = makeToken([]); // no required scopes needed
    const channels = await composeChannels([productWithChildren], token);

    expect(channels[0].id).toBe("calendar:parent");
    expect(channels[0].children?.[0].id).toBe("calendar:child1");
    expect(channels[0].children?.[1].id).toBe("calendar:child2:nested");
  });

  it("returns an empty array when no products match", async () => {
    const token = makeToken([]);
    const channels = await composeChannels([calendarFake, mailFake], token);
    expect(channels).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// resolveProductForChannelId
// ---------------------------------------------------------------------------

describe("resolveProductForChannelId", () => {
  const products = [calendarFake, mailFake, contactsFake];

  it("resolves by channel-id prefix", () => {
    expect(resolveProductForChannelId(products, "calendar:primary")).toBe(calendarFake);
    expect(resolveProductForChannelId(products, "mail:INBOX")).toBe(mailFake);
    expect(resolveProductForChannelId(products, "contacts:contacts")).toBe(contactsFake);
  });

  it("returns null for unknown prefix", () => {
    expect(resolveProductForChannelId(products, "tasks:default-list")).toBeNull();
  });

  it("returns null for un-namespaced id", () => {
    expect(resolveProductForChannelId(products, "noprefix")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// resolveProductForLinkType
// ---------------------------------------------------------------------------

describe("resolveProductForLinkType", () => {
  const products = [calendarFake, mailFake, contactsFake];

  it("resolves by link type string", () => {
    expect(resolveProductForLinkType(products, "event")).toBe(calendarFake);
    expect(resolveProductForLinkType(products, "email")).toBe(mailFake);
    expect(resolveProductForLinkType(products, "contact")).toBe(contactsFake);
  });

  it("returns null for unknown link type", () => {
    expect(resolveProductForLinkType(products, "unknown-type")).toBeNull();
  });
});
