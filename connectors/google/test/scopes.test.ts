import { describe, it, expect } from "vitest";
import { OPTIONAL_SCOPE_GROUPS, PRODUCTS } from "../src/scopes";

const EXPECTED_KEYS = new Set(["mail", "calendar", "tasks", "contacts"]);

describe("OPTIONAL_SCOPE_GROUPS", () => {
  it("contains exactly the four product group ids", () => {
    const ids = OPTIONAL_SCOPE_GROUPS.map((g) => g.id);
    expect(new Set(ids)).toEqual(EXPECTED_KEYS);
  });

  it("has unique group ids", () => {
    const ids = OPTIONAL_SCOPE_GROUPS.map((g) => g.id);
    expect(ids.length).toBe(new Set(ids).size);
  });

  it("every group has default: true", () => {
    for (const group of OPTIONAL_SCOPE_GROUPS) {
      expect(group.default).toBe(true);
    }
  });

  it("calendar group includes calendar.events scope", () => {
    const calendarGroup = OPTIONAL_SCOPE_GROUPS.find((g) => g.id === "calendar");
    expect(calendarGroup).toBeDefined();
    expect(calendarGroup!.scopes).toContain(
      "https://www.googleapis.com/auth/calendar.events"
    );
  });

  it("contacts group includes both People API scopes", () => {
    const contactsGroup = OPTIONAL_SCOPE_GROUPS.find((g) => g.id === "contacts");
    expect(contactsGroup).toBeDefined();
    expect(contactsGroup!.scopes).toContain(
      "https://www.googleapis.com/auth/contacts.readonly"
    );
    expect(contactsGroup!.scopes).toContain(
      "https://www.googleapis.com/auth/contacts.other.readonly"
    );
  });

  it("mail group includes gmail.modify scope", () => {
    const mailGroup = OPTIONAL_SCOPE_GROUPS.find((g) => g.id === "mail");
    expect(mailGroup).toBeDefined();
    expect(mailGroup!.scopes).toContain(
      "https://www.googleapis.com/auth/gmail.modify"
    );
  });

  it("tasks group includes tasks scope", () => {
    const tasksGroup = OPTIONAL_SCOPE_GROUPS.find((g) => g.id === "tasks");
    expect(tasksGroup).toBeDefined();
    expect(tasksGroup!.scopes).toContain(
      "https://www.googleapis.com/auth/tasks"
    );
  });
});

describe("PRODUCTS metadata array", () => {
  it("has one entry per product key", () => {
    const keys = PRODUCTS.map((p) => p.key);
    expect(new Set(keys)).toEqual(EXPECTED_KEYS);
  });

  it("each product's scopeGroupId matches its key", () => {
    for (const product of PRODUCTS) {
      expect(product.scopeGroupId).toBe(product.key);
    }
  });

  it("each product's scopeGroupId matches an OPTIONAL_SCOPE_GROUPS id", () => {
    const groupIds = new Set(OPTIONAL_SCOPE_GROUPS.map((g) => g.id));
    for (const product of PRODUCTS) {
      expect(groupIds.has(product.scopeGroupId)).toBe(true);
    }
  });
});
