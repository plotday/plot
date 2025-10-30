import { describe, it, expect } from "vitest";
import { mergeToolPermissions, groupPermissions, type ToolPermission } from "../permissions";

describe("Permissions", () => {
  describe("mergeToolPermissions", () => {
    it("should merge permissions with same domain and entity", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "plot", entity: "activities", flags: ["write"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged).toEqual({
        plot: {
          activities: ["read", "write"],
        },
      });
    });

    it("should keep separate entities in same domain", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "plot", entity: "priorities", flags: ["read"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged).toEqual({
        plot: {
          activities: ["read"],
          priorities: ["read"],
        },
      });
    });

    it("should keep separate domains", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged).toEqual({
        network: {
          "https://api.example.com/*": ["use"],
        },
        plot: {
          activities: ["read"],
        },
      });
    });

    it("should sort domains, entities, and flags", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "priorities", flags: ["write", "read"] },
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
        { domain: "plot", entity: "activities", flags: ["read"] },
      ];

      const merged = mergeToolPermissions(permissions);

      // Domains should be sorted: network, plot
      expect(Object.keys(merged)).toEqual(["network", "plot"]);
      // Entities should be sorted: activities, priorities
      expect(Object.keys(merged.plot)).toEqual(["activities", "priorities"]);
      // Flags should be sorted: read, write
      expect(merged.plot.priorities).toEqual(["read", "write"]);
    });

    it("should handle empty permissions array", () => {
      const merged = mergeToolPermissions([]);
      expect(merged).toEqual({});
    });

    it("should consolidate network URLs with wildcards", () => {
      const permissions: ToolPermission[] = [
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
        { domain: "network", entity: "https://api.example.com/v1/*", flags: ["use"] },
      ];

      const merged = mergeToolPermissions(permissions);

      // Both patterns are kept since the consolidation logic is conservative
      expect(merged.network).toHaveProperty("https://api.example.com/*");
      expect(merged.network).toHaveProperty("https://api.example.com/v1/*");
    });

    it("should handle unrestricted network access", () => {
      const permissions: ToolPermission[] = [
        { domain: "network", entity: "*", flags: ["use"] },
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
      ];

      const merged = mergeToolPermissions(permissions);

      // Should only keep the wildcard
      expect(merged).toEqual({
        network: {
          "*": ["use"],
        },
      });
    });

    it("should deduplicate identical permissions", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "plot", entity: "activities", flags: ["read"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged).toEqual({
        plot: {
          activities: ["read"],
        },
      });
    });

    it("should handle multiple network URLs that don't overlap", () => {
      const permissions: ToolPermission[] = [
        { domain: "network", entity: "https://api.github.com/*", flags: ["use"] },
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged.network).toHaveProperty("https://api.example.com/*");
      expect(merged.network).toHaveProperty("https://api.github.com/*");
    });

    it("should use union (OR) semantics for flag merging", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read"] },
        { domain: "plot", entity: "activities", flags: ["write"] },
        { domain: "plot", entity: "activities", flags: ["update"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged.plot.activities).toEqual(["read", "update", "write"]);
    });

    it("should handle complex nested permissions", () => {
      const permissions: ToolPermission[] = [
        { domain: "plot", entity: "activities", flags: ["read", "write"] },
        { domain: "plot", entity: "priorities", flags: ["read"] },
        { domain: "plot", entity: "contacts", flags: ["read"] },
        { domain: "network", entity: "https://api.github.com/*", flags: ["use"] },
        { domain: "network", entity: "https://api.example.com/*", flags: ["use"] },
      ];

      const merged = mergeToolPermissions(permissions);

      expect(merged).toEqual({
        network: {
          "https://api.example.com/*": ["use"],
          "https://api.github.com/*": ["use"],
        },
        plot: {
          activities: ["read", "write"],
          contacts: ["read"],
          priorities: ["read"],
        },
      });
    });
  });

  describe("groupPermissions", () => {
    it("should group permissions by tool ID", () => {
      const toolPermissions = {
        "Tool1:Tool2:Plot": { activities: { read: true } },
        "Tool1:Tool2:Store": { data: { write: true } },
        "Tool3:Plot": { priorities: { read: true } },
      };

      const grouped = groupPermissions(toolPermissions);

      expect(grouped).toHaveProperty("Plot");
      expect(grouped).toHaveProperty("Store");
      expect(grouped.Plot).toHaveLength(2);
      expect(grouped.Store).toHaveLength(1);
    });

    it("should handle empty permissions", () => {
      const grouped = groupPermissions({});
      expect(grouped).toEqual({});
    });

    it("should handle single tool", () => {
      const toolPermissions = {
        "Plot": { activities: { read: true } },
      };

      const grouped = groupPermissions(toolPermissions);

      expect(grouped).toHaveProperty("Plot");
      expect(grouped.Plot).toHaveLength(1);
      expect(grouped.Plot[0]).toEqual({ activities: { read: true } });
    });

    it("should handle multiple instances of same tool", () => {
      const toolPermissions = {
        "Network": { url: "https://api1.com" },
        "Tool1:Network": { url: "https://api2.com" },
        "Tool1:Tool2:Network": { url: "https://api3.com" },
      };

      const grouped = groupPermissions(toolPermissions);

      expect(grouped).toHaveProperty("Network");
      expect(grouped.Network).toHaveLength(3);
    });
  });
});
