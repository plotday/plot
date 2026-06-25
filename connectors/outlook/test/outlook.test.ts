/**
 * Integration tests: composition, routing, and product-status logic wired to
 * the REAL product registry (mail / calendar / contacts) and real link types.
 *
 * Network-safety contract
 * -----------------------
 * mail.getRawChannels() and calendar.getRawChannels() call Microsoft Graph.
 * We avoid them entirely by either:
 *   - passing a token whose scopes gate those products OUT (empty scopes), or
 *   - relying only on contacts, which returns a synthetic channel with NO fetch.
 * All assertions here are deterministic with zero network I/O.
 */
import { describe, it, expect } from "vitest";
import type { AuthToken } from "@plotday/twister/tools/integrations";
import { composeChannels, resolveProductForChannelId, resolveProductForLinkType } from "../src/compose";
import { computeProductStatus } from "../src/product-status";
import { PRODUCTS_BY_KEY } from "../src/products/product";
import { CONTACTS_SCOPES } from "../src/products/contacts";
import { OUTLOOK_MAIL_SCOPES } from "@plotday/connector-outlook-mail";
import { OUTLOOK_CALENDAR_SCOPE } from "@plotday/connector-outlook-calendar";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeToken(scopes: string[]): AuthToken {
  return { accessToken: "fake-access-token", scopes } as unknown as AuthToken;
}

const REAL_PRODUCTS = Object.values(PRODUCTS_BY_KEY);

// ---------------------------------------------------------------------------
// resolveProductForLinkType — real PRODUCTS_BY_KEY + real link types
// ---------------------------------------------------------------------------

describe("resolveProductForLinkType (real products)", () => {
  it('"event" resolves to the calendar product', () => {
    const p = resolveProductForLinkType(REAL_PRODUCTS, "event");
    expect(p?.key).toBe("calendar");
  });

  it('"email" resolves to the mail product', () => {
    const p = resolveProductForLinkType(REAL_PRODUCTS, "email");
    expect(p?.key).toBe("mail");
  });

  it("an unknown link type returns null", () => {
    expect(resolveProductForLinkType(REAL_PRODUCTS, "task")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// resolveProductForChannelId — real PRODUCTS_BY_KEY
// ---------------------------------------------------------------------------

describe("resolveProductForChannelId (real products)", () => {
  it('"calendar:AAMk..." resolves to the calendar product', () => {
    const p = resolveProductForChannelId(REAL_PRODUCTS, "calendar:AAMkABcDeFgHiJkLm");
    expect(p?.key).toBe("calendar");
  });

  it('"mail:INBOX" resolves to the mail product', () => {
    const p = resolveProductForChannelId(REAL_PRODUCTS, "mail:INBOX");
    expect(p?.key).toBe("mail");
  });

  it('"contacts:contacts" resolves to the contacts product', () => {
    const p = resolveProductForChannelId(REAL_PRODUCTS, "contacts:contacts");
    expect(p?.key).toBe("contacts");
  });

  it("un-prefixed id returns null", () => {
    expect(resolveProductForChannelId(REAL_PRODUCTS, "INBOX")).toBeNull();
  });

  it("unknown prefix returns null", () => {
    expect(resolveProductForChannelId(REAL_PRODUCTS, "tasks:default")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// composeChannels — real PRODUCTS_BY_KEY, network-free
// ---------------------------------------------------------------------------

describe("composeChannels (real products, no network)", () => {
  it("returns [] when no scopes are granted (all products gated out)", async () => {
    const token = makeToken([]);
    const channels = await composeChannels(REAL_PRODUCTS, token);
    expect(channels).toEqual([]);
  });

  it("returns exactly the contacts synthetic channel when only contacts scopes are granted", async () => {
    // mail + calendar are gated out (their scopes absent); contacts needs no API call.
    const token = makeToken(CONTACTS_SCOPES);
    const channels = await composeChannels(REAL_PRODUCTS, token);

    expect(channels).toHaveLength(1);
    expect(channels[0].id).toBe("contacts:contacts");
    expect(channels[0].title).toBe("Contacts");
  });

  it("namespaces the contacts channel id with the 'contacts:' prefix", async () => {
    const token = makeToken(CONTACTS_SCOPES);
    const channels = await composeChannels(REAL_PRODUCTS, token);
    expect(channels[0].id.startsWith("contacts:")).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// computeProductStatus — real PRODUCTS_BY_KEY, mixed scope scenario
// ---------------------------------------------------------------------------

describe("computeProductStatus (real products)", () => {
  // Grant mail + contacts scopes but NOT calendar.
  const mailAndContactsScopes = [...OUTLOOK_MAIL_SCOPES, ...CONTACTS_SCOPES];

  it("calendar reports scope-missing when calendar scope is absent", () => {
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: mailAndContactsScopes,
      enabledChannelCount: {},
      locallyOff: {},
    });
    const cal = statuses.find((s) => s.key === "calendar");
    expect(cal).toEqual({ key: "calendar", enabled: false, reason: "scope-missing" });
  });

  it("mail reports no-channels when mail scope is granted but no channels are enabled", () => {
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: mailAndContactsScopes,
      enabledChannelCount: {},
      locallyOff: {},
    });
    const mail = statuses.find((s) => s.key === "mail");
    expect(mail).toEqual({ key: "mail", enabled: false, reason: "no-channels" });
  });

  it("mail reports granted when mail scope is granted and ≥1 channel is enabled", () => {
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: mailAndContactsScopes,
      enabledChannelCount: { mail: 1 },
      locallyOff: {},
    });
    const mail = statuses.find((s) => s.key === "mail");
    expect(mail).toEqual({ key: "mail", enabled: true, reason: "granted" });
  });

  it("contacts reports granted on scope alone (channelless product)", () => {
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: mailAndContactsScopes,
      enabledChannelCount: {},
      locallyOff: {},
    });
    const contacts = statuses.find((s) => s.key === "contacts");
    expect(contacts).toEqual({ key: "contacts", enabled: true, reason: "granted" });
  });

  it("all three products report scope-missing when no scopes granted", () => {
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: [],
      enabledChannelCount: {},
      locallyOff: {},
    });
    for (const s of statuses) {
      expect(s.reason).toBe("scope-missing");
      expect(s.enabled).toBe(false);
    }
  });

  it("all three products report granted when all scopes present and channels enabled", () => {
    const allScopes = [...OUTLOOK_MAIL_SCOPES, OUTLOOK_CALENDAR_SCOPE, ...CONTACTS_SCOPES];
    const statuses = computeProductStatus(REAL_PRODUCTS, {
      grantedScopes: allScopes,
      enabledChannelCount: { mail: 2, calendar: 1 },
      locallyOff: {},
    });
    for (const s of statuses) {
      expect(s.reason).toBe("granted");
      expect(s.enabled).toBe(true);
    }
  });
});
