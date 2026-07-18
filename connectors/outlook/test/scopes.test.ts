import { describe, it, expect } from "vitest";
import { OPTIONAL_SCOPE_GROUPS, PRODUCTS } from "../src/scopes";

describe("outlook scopes", () => {
  it("defines mail, calendar, contacts groups with matching ids", () => {
    expect(OPTIONAL_SCOPE_GROUPS.map(g => g.id)).toEqual(["mail", "calendar", "contacts"]);
  });
  it("each product's scopeGroupId equals its key (three-way invariant)", () => {
    for (const p of PRODUCTS) expect(p.scopeGroupId).toBe(p.key);
  });
  it("mail group carries readwrite + send scopes", () => {
    const mail = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "mail")!;
    expect(mail.scopes).toEqual([
      "https://graph.microsoft.com/mail.readwrite",
      "https://graph.microsoft.com/mail.send",
    ]);
  });
  it("contacts group carries people.read + contacts.read", () => {
    const c = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "contacts")!;
    expect(c.scopes).toEqual([
      "https://graph.microsoft.com/people.read",
      "https://graph.microsoft.com/contacts.read",
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
