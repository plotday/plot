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
        twistInstanceId: "pa-1",
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
        network.createWebhook({}, callback)
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
        twistInstanceId: "pa-1",
        twistId: "test-twist",
        environment: "personal",
        baseUrl: "https://api.plot.com",
        path: ["Tool1", "Network"],
      });

      const callback = async function webhookCallback(_request: any) {
        return { received: true };
      };

      const webhookUrl = await network.createWebhook({}, callback);

      expect(webhookUrl).toContain("https://api.plot.com/hook/");
      expect(mockCallbacksStub.create).toHaveBeenCalled();
    });
  });

  describe("createWebhook Gmail routing", () => {
    const makeNetwork = (opts: { store?: any; env?: any }) => {
      const mockCallbacksStub = {
        create: vi.fn().mockResolvedValue("doid:cb_token"),
      };
      const mockCallbacksNamespace = {
        idFromName: vi.fn(() => "mock-id"),
        get: vi.fn(() => mockCallbacksStub),
      } as any;
      return new Network({
        callbacks: mockCallbacksNamespace,
        twistInstanceId: "pa-1",
        twistId: "test-twist",
        environment: "personal",
        baseUrl: "https://api.plot.com",
        path: ["Tool1", "Network"],
        store: opts.store,
        env: opts.env,
      });
    };

    // A store holding a Gmail-scoped Google auth token, as it would when the
    // user also has the Gmail connector installed on the same Google account.
    const gmailScopedStore = () => ({
      list: vi.fn(async (prefix: string) =>
        prefix === "auth_token:google:" ? ["auth_token:google:actor-1"] : []
      ),
      get: vi.fn(async () => ({
        scopes: ["https://www.googleapis.com/auth/gmail.modify"],
      })),
    });

    const emptyStore = () => ({
      list: vi.fn(async () => [] as string[]),
      get: vi.fn(async () => null),
    });

    it("does NOT route a provider-less webhook (calendar/drive) to Gmail Pub/Sub even when a Gmail-scoped Google token exists", async () => {
      const network = makeNetwork({
        store: gmailScopedStore(),
        // Only GCP_PROJECT_ID is set. If the call wrongly took the Gmail
        // Pub/Sub path it would throw "GCP configuration missing"; the
        // default HTTPS path ignores GCP config and returns a webhook URL.
        env: { GCP_PROJECT_ID: "plot-test" } as any,
      });

      const callback = async function onCalendarWebhook(_r: any) {};
      const url = await network.createWebhook({}, callback);

      expect(url).toContain("https://api.plot.com/hook/");
    });

    it("routes to Gmail Pub/Sub only when the caller explicitly opts in with { pubsub: 'gmail' }", async () => {
      const network = makeNetwork({
        store: emptyStore(),
        env: { GCP_PROJECT_ID: "plot-test" } as any,
      });

      const callback = async function onGmailWebhook(_r: any) {};

      // The Pub/Sub path requires full GCP config; with only GCP_PROJECT_ID
      // set it throws — proving the Pub/Sub branch was taken. The default
      // HTTPS path would have returned a URL without touching GCP config.
      await expect(
        network.createWebhook({ pubsub: "gmail" }, callback)
      ).rejects.toThrow("GCP configuration missing");
    });

    it("routes { pubsub: 'workspace' } to the Pub/Sub path", async () => {
      const network = makeNetwork({
        store: emptyStore(),
        env: { GCP_PROJECT_ID: "plot-test" } as any,
      });

      const callback = async function onChatWebhook(_r: any) {};

      await expect(
        network.createWebhook({ pubsub: "workspace" }, callback)
      ).rejects.toThrow("GCP configuration missing");
    });
  });

  describe("PATH constant", () => {
    it("should have correct webhook path", () => {
      expect(Network.PATH).toBe("/hook/:token");
    });
  });
});
