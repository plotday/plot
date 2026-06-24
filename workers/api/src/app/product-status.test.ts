import { describe, expect, it } from "vitest";

import {
  computeProductStatus,
  productKeyOf,
  type OptionalScopeGroup,
  type ProductInfo,
} from "./product-status";

/**
 * Unit tests for the combined-connector productStatus computation
 * (spec §4.2). Pure function — no DB / Durable Objects involved.
 */

const PRODUCTS: ProductInfo[] = [
  { key: "mail", label: "Gmail", description: "", icon: "", scopeGroupId: "mail" },
  { key: "calendar", label: "Calendar", description: "", icon: "", scopeGroupId: "calendar" },
  { key: "tasks", label: "Tasks", description: "", icon: "", scopeGroupId: "tasks" },
];

const SCOPE_GROUPS: OptionalScopeGroup[] = [
  { id: "mail", scopes: ["scope.mail"] },
  { id: "calendar", scopes: ["scope.cal.events", "scope.cal.list"] },
  { id: "tasks", scopes: ["scope.tasks"] },
];

describe("productKeyOf", () => {
  it("returns the prefix before the first colon", () => {
    expect(productKeyOf("calendar:primary")).toBe("calendar");
    expect(productKeyOf("mail:Label_42")).toBe("mail");
  });

  it("splits on the FIRST colon only (rawId may contain colons)", () => {
    expect(productKeyOf("calendar:abc:def")).toBe("calendar");
  });

  it("returns null when there is no prefix", () => {
    expect(productKeyOf("primary")).toBeNull();
  });
});

describe("computeProductStatus", () => {
  it("reports scope-missing when a product's required scope is absent", () => {
    const status = computeProductStatus(
      PRODUCTS,
      SCOPE_GROUPS,
      // Only mail granted; calendar + tasks scopes absent.
      ["scope.mail"],
      ["mail:INBOX"],
    );
    const tasks = status.find((s) => s.key === "tasks")!;
    const calendar = status.find((s) => s.key === "calendar")!;
    expect(tasks).toEqual({ key: "tasks", enabled: false, reason: "scope-missing" });
    expect(calendar).toEqual({
      key: "calendar",
      enabled: false,
      reason: "scope-missing",
    });
  });

  it("requires ALL of a multi-scope group to be granted", () => {
    const status = computeProductStatus(
      PRODUCTS,
      SCOPE_GROUPS,
      // Calendar needs both scopes; only one granted.
      ["scope.cal.events"],
      ["calendar:primary"],
    );
    const calendar = status.find((s) => s.key === "calendar")!;
    expect(calendar.reason).toBe("scope-missing");
    expect(calendar.enabled).toBe(false);
  });

  it("reports no-channels when scoped but zero enabled channels of that prefix", () => {
    const status = computeProductStatus(
      PRODUCTS,
      SCOPE_GROUPS,
      // Tasks scope granted...
      ["scope.tasks"],
      // ...but no tasks:* channel is enabled (a mail channel is, irrelevant).
      ["mail:INBOX"],
    );
    const tasks = status.find((s) => s.key === "tasks")!;
    expect(tasks).toEqual({ key: "tasks", enabled: false, reason: "no-channels" });
  });

  it("reports granted when scoped and >=1 enabled channel of that prefix", () => {
    const status = computeProductStatus(
      PRODUCTS,
      SCOPE_GROUPS,
      ["scope.mail", "scope.cal.events", "scope.cal.list", "scope.tasks"],
      ["mail:INBOX", "calendar:primary", "tasks:list-1"],
    );
    expect(status).toEqual([
      { key: "mail", enabled: true, reason: "granted" },
      { key: "calendar", enabled: true, reason: "granted" },
      { key: "tasks", enabled: true, reason: "granted" },
    ]);
  });

  it("treats a product with no matching scope group as having no required scopes", () => {
    const products: ProductInfo[] = [
      { key: "contacts", label: "Contacts", description: "", icon: "", scopeGroupId: "contacts" },
    ];
    // No "contacts" group declared → required scopes empty → never scope-missing.
    const noChannels = computeProductStatus(products, [], [], []);
    expect(noChannels[0]).toEqual({
      key: "contacts",
      enabled: false,
      reason: "no-channels",
    });
    const granted = computeProductStatus(products, [], [], ["contacts:contacts"]);
    expect(granted[0]).toEqual({ key: "contacts", enabled: true, reason: "granted" });
  });

  it("ignores enabled channels whose prefix doesn't match any product key", () => {
    const status = computeProductStatus(
      PRODUCTS,
      SCOPE_GROUPS,
      ["scope.mail"],
      // Unprefixed + foreign-prefix channels don't count toward mail.
      ["INBOX", "drive:file-1"],
    );
    const mail = status.find((s) => s.key === "mail")!;
    expect(mail).toEqual({ key: "mail", enabled: false, reason: "no-channels" });
  });
});
