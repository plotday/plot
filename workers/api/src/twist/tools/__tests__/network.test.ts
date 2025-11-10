import { describe, expect, it, vi } from "vitest";

import { Network } from "../network";

describe("Network", () => {
  describe("Permissions", () => {
    it("should return permissions for single URL", () => {
      const permissions = Network.Permissions({
        urls: ["https://api.example.com/*"],
      });

      expect(permissions).toEqual([
        {
          domain: "network",
          entity: "https://api.example.com/*",
          flags: ["use"],
        },
      ]);
    });

    it("should return permissions for multiple URLs", () => {
      const permissions = Network.Permissions({
        urls: ["https://api.github.com/*", "https://api.example.com/*"],
      });

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

    it("should return empty array when no URLs provided", () => {
      const permissions = Network.Permissions({});
      expect(permissions).toEqual([]);
    });

    it("should return empty array when options not provided", () => {
      const permissions = Network.Permissions();
      expect(permissions).toEqual([]);
    });

    it("should handle wildcard URL", () => {
      const permissions = Network.Permissions({
        urls: ["*"],
      });

      expect(permissions).toEqual([
        {
          domain: "network",
          entity: "*",
          flags: ["use"],
        },
      ]);
    });
  });

  describe("constructor", () => {
    it("should create instance without options", () => {
      const network = new Network();
      expect(network).toBeDefined();
    });

    it("should create instance with URL options", () => {
      const network = new Network({
        urls: ["https://api.example.com/*"],
      });
      expect(network).toBeDefined();
    });

    it("should initialize webhook functionality with full options", () => {
      const mockCallbacksNamespace = {
        idFromName: vi.fn(() => "mock-id"),
        get: vi.fn(() => ({ create: vi.fn() })),
      } as any;

      const network = new Network({
        urls: ["https://api.example.com/*"],
        callbacks: mockCallbacksNamespace,
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "personal",
        baseUrl: "https://api.plot.com",
        path: ["Tool1", "Network"],
      });

      expect(network).toBeDefined();
      expect(mockCallbacksNamespace.idFromName).toHaveBeenCalledWith("pa-1");
    });
  });

  describe("createWebhook", () => {
    it("should throw error when webhook functionality not initialized", async () => {
      const network = new Network();
      const callback = async function testCallback() {};

      await expect(
        network.createWebhook({ callback })
      ).rejects.toThrow("Webhook functionality not initialized");
    });

    it("should create webhook with initialized options", async () => {
      const mockCallbacksStub = {
        create: vi.fn().mockResolvedValue("cb_webhook_token"),
      };

      const mockCallbacksNamespace = {
        idFromName: vi.fn(() => "mock-id"),
        get: vi.fn(() => mockCallbacksStub),
      } as any;

      const network = new Network({
        callbacks: mockCallbacksNamespace,
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "personal",
        baseUrl: "https://api.plot.com",
        path: ["Tool1", "Network"],
      });

      const callback = async function webhookCallback(_request: any) {
        return { received: true };
      };

      const webhookUrl = await network.createWebhook({ callback });

      expect(webhookUrl).toContain("https://api.plot.com/hook/");
      expect(mockCallbacksStub.create).toHaveBeenCalled();
    });
  });

  describe("PATH constant", () => {
    it("should have correct webhook path", () => {
      expect(Network.PATH).toBe("/hook/:token");
    });
  });
});
