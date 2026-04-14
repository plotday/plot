import { describe, it, expect, beforeEach } from "vitest";
import { createTool, collectToolPermissions } from "../tools/factory";
import { createMockEnv } from "./utils/mocks";
import { ThreadAccess, PriorityAccess, ContactAccess } from "@plotday/twister/tools/plot";

describe("Tool Factory", () => {
  let context: any;

  beforeEach(() => {
    const env = createMockEnv();

    context = {
      twistId: "test-twist",
      environment: "production" as const,
      db: {} as any,
      priorityId: "priority-1",
      twistInstanceId: "pa-1",
      storage: env.STORAGE,
      callbacks: env.CALLBACKS,
      logSubscriptions: env.LOG_SUBSCRIPTIONS,
      usage: env.USAGE,
      env,
      ctx: { exports: { waitUntil: () => {}, passThroughOnException: () => {} } },
    };
  });

  describe("createTool", () => {
    it("should create Plot tool", () => {
      const tool = createTool([], "Plot", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Plot");
    });

    it("should create AI tool", () => {
      const tool = createTool([], "AI", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("AI");
    });

    it("should create Network tool", () => {
      const tool = createTool([], "Network", { urls: ["https://api.example.com/*"] }, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Network");
    });

    it("should create Integrations tool", () => {
      const tool = createTool([], "Integrations", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Integrations");
    });

    it("should create Store tool", () => {
      const tool = createTool([], "Store", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Store");
    });

    it("should create Tasks tool", () => {
      const tool = createTool([], "Tasks", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Tasks");
    });

    it("should create Callbacks tool", () => {
      const tool = createTool([], "Callbacks", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Callbacks");
    });

    it("should create Twists tool", () => {
      const tool = createTool([], "Twists", {}, context);
      expect(tool).toBeDefined();
      expect(tool.constructor.name).toBe("Twists");
    });

    it("should throw error for unknown tool", () => {
      expect(() => createTool([], "UnknownTool", {}, context)).toThrow(
        "Unknown tool: UnknownTool"
      );
    });

    it("should pass correct options to tools", () => {
      const plotOptions = {
        activities: { access: ["read", "write"] },
        priorities: { access: ["read"] },
      };
      const tool = createTool([], "Plot", plotOptions, context);
      expect(tool).toBeDefined();
    });

    it("should pass correct path to tools", () => {
      const path = ["Tool1", "Tool2"];
      const tool = createTool(path, "Store", {}, context);
      expect(tool).toBeDefined();
    });
  });

  describe("collectToolPermissions", () => {
    it("should collect Network permissions", () => {
      const options = {
        urls: ["https://api.github.com/*", "https://api.example.com/*"],
      };
      const permissions = collectToolPermissions("Network", options);

      expect(permissions).toHaveLength(2);
      expect(permissions[0]).toEqual({
        domain: "network",
        entity: "https://api.github.com/*",
        flags: ["use"],
      });
      expect(permissions[1]).toEqual({
        domain: "network",
        entity: "https://api.example.com/*",
        flags: ["use"],
      });
    });

    it("should collect Plot permissions", () => {
      const options = {
        activity: { access: ThreadAccess.Respond },
        priority: { access: PriorityAccess.Full },
        contact: { access: ContactAccess.Read },
      };
      const permissions = collectToolPermissions("Plot", options);

      expect(permissions.length).toBeGreaterThan(0);
      expect(permissions).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            domain: "plot",
            flags: expect.any(Array),
          }),
        ])
      );
    });

    it("should return empty array for tools without permissions", () => {
      const permissions = collectToolPermissions("Store", {});
      expect(permissions).toEqual([]);
    });

    it("should return permissions for AI tool", () => {
      const permissions = collectToolPermissions("AI", {});
      expect(permissions).toEqual([{ domain: "ai", entity: "prompt", flags: ["use"] }]);
    });

    it("should return empty array for Tasks tool", () => {
      const permissions = collectToolPermissions("Tasks", {});
      expect(permissions).toEqual([]);
    });

    it("should return empty array for Callbacks tool", () => {
      const permissions = collectToolPermissions("Callbacks", {});
      expect(permissions).toEqual([]);
    });

    it("should handle undefined options for Network", () => {
      const permissions = collectToolPermissions("Network", undefined);
      expect(permissions).toEqual([]);
    });

    it("should handle empty options for Plot", () => {
      const permissions = collectToolPermissions("Plot", {});
      expect(permissions).toEqual([]);
    });
  });
});
