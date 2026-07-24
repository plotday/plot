import { describe, it, expect } from "vitest";
import { OPTIONAL_SCOPE_GROUPS, OUTLOOK_SCOPES, PRODUCTS } from "../src/scopes";

describe("outlook scopes", () => {
  it("always requires User.Read, independent of optional product groups", () => {
    // GET /me (ensureUserEmailFn's getProfile call) needs User.Read regardless
    // of which mail/calendar/contacts groups the user enables — without it
    // Graph returns 403 on the very first sync batch.
    expect(OUTLOOK_SCOPES.required).toEqual([
      "https://graph.microsoft.com/User.Read",
    ]);
  });
  it("defines mail, calendar, contacts groups with matching ids", () => {
    expect(OPTIONAL_SCOPE_GROUPS.map(g => g.id)).toEqual(["mail", "calendar", "contacts"]);
  });
  it("each product's scopeGroupId equals its key (three-way invariant)", () => {
    for (const p of PRODUCTS) expect(p.scopeGroupId).toBe(p.key);
  });
  it("mail group carries readwrite + send scopes", () => {
    const mail = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "mail")!;
    expect(mail.scopes).toEqual([
      "https://graph.microsoft.com/Mail.ReadWrite",
      "https://graph.microsoft.com/Mail.Send",
    ]);
  });
  it("contacts group carries people.read + contacts.read", () => {
    const c = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "contacts")!;
    expect(c.scopes).toEqual([
      "https://graph.microsoft.com/People.Read",
      "https://graph.microsoft.com/Contacts.Read",
    ]);
  });
  it("gives mail and calendar each a distinct channelNoun", () => {
    const byKey = new Map(PRODUCTS.map((p) => [p.key, p.channelNoun]));
    expect(byKey.get("mail")).toEqual({ singular: "folder", plural: "folders" });
    expect(byKey.get("calendar")).toEqual({
      singular: "calendar",
      plural: "calendars",
    });
  });
});
