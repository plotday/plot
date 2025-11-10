import { describe, it, expect, beforeEach, vi } from "vitest";
import { Callbacks } from "../callbacks";

describe("Callbacks", () => {
  let callbacks: Callbacks;
  let mockCallbacksStub: any;
  let mockCallbacksNamespace: any;

  beforeEach(() => {
    mockCallbacksStub = {
      create: vi.fn().mockResolvedValue("cb_test_token_123"),
      callCallback: vi.fn().mockResolvedValue({ success: true }),
      delete: vi.fn().mockResolvedValue(undefined),
      deleteAll: vi.fn().mockResolvedValue(undefined),
    };

    mockCallbacksNamespace = {
      idFromName: vi.fn(() => "mock-callbacks-id"),
      get: vi.fn(() => mockCallbacksStub),
    } as any;

    callbacks = new Callbacks({
      callbacks: mockCallbacksNamespace,
      priorityTwistId: "pa-1",
      twistId: "test-twist",
      environment: "production",
      path: ["Tool1", "Callbacks"],
    });
  });

  describe("create", () => {
    it("should create callback with function name", async () => {
      const testFunction = async function testCallback() {
        return "result";
      };

      const token = await callbacks.create(testFunction);

      expect(token).toBe("cb_test_token_123");
      expect(mockCallbacksStub.create).toHaveBeenCalledWith({
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "production",
        path: ["Tool1"],
        functionName: "testCallback",
        extraArgs: [],
      });
    });

    it("should create callback with extra arguments", async () => {
      const testFunction = async function testCallback() {
        return "result";
      };

      const token = await callbacks.create(testFunction, "arg1", "arg2");

      expect(token).toBe("cb_test_token_123");
      expect(mockCallbacksStub.create).toHaveBeenCalledWith({
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "production",
        path: ["Tool1"],
        functionName: "testCallback",
        extraArgs: ["arg1", "arg2"],
      });
    });

    it("should throw error for anonymous function", async () => {
      const anonymousFunction = async function () {
        return "result";
      };
      // Remove function name
      Object.defineProperty(anonymousFunction, "name", { value: "" });

      await expect(callbacks.create(anonymousFunction)).rejects.toThrow(
        "Cannot create callback"
      );
    });
  });

  describe("createFromParent", () => {
    it("should create callback targeting parent path", async () => {
      const testFunction = async function parentCallback() {
        return "result";
      };

      const token = await callbacks.createFromParent(testFunction);

      expect(token).toBe("cb_test_token_123");
      expect(mockCallbacksStub.create).toHaveBeenCalledWith({
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "production",
        path: [], // Parent of ["Tool1"]
        functionName: "parentCallback",
        extraArgs: [],
      });
    });

    it("should create callback with extra arguments", async () => {
      const testFunction = async function parentCallback() {
        return "result";
      };

      const _token = await callbacks.createFromParent(testFunction, "data");

      expect(mockCallbacksStub.create).toHaveBeenCalledWith({
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "production",
        path: [],
        functionName: "parentCallback",
        extraArgs: ["data"],
      });
    });
  });

  describe("run", () => {
    it("should run callback with arguments", async () => {
      const result = await callbacks.run("cb_test_token_123", { data: "test" });

      expect(result).toEqual({ success: true });
      expect(mockCallbacksStub.callCallback).toHaveBeenCalledWith(
        "cb_test_token_123",
        { data: "test" }
      );
    });

    it("should run callback without arguments", async () => {
      await callbacks.run("cb_test_token_123");

      expect(mockCallbacksStub.callCallback).toHaveBeenCalledWith(
        "cb_test_token_123"
      );
    });

    it("should run callback with multiple arguments", async () => {
      await callbacks.run("cb_test_token_123", "arg1", "arg2", "arg3");

      expect(mockCallbacksStub.callCallback).toHaveBeenCalledWith(
        "cb_test_token_123",
        "arg1",
        "arg2",
        "arg3"
      );
    });
  });

  describe("delete", () => {
    it("should delete callback", async () => {
      await callbacks.delete("cb_test_token_123");

      expect(mockCallbacksStub.delete).toHaveBeenCalledWith("cb_test_token_123");
    });
  });

  describe("deleteAll", () => {
    it("should delete all callbacks for current path", async () => {
      await callbacks.deleteAll();

      expect(mockCallbacksStub.deleteAll).toHaveBeenCalledWith({
        priorityTwistId: "pa-1",
        twistId: "test-twist",
        environment: "production",
        path: ["Tool1"],
      });
    });
  });

  describe("integration", () => {
    it("should create and run callback", async () => {
      const testFunction = async function myCallback() {
        return "result";
      };

      const token = await callbacks.create(testFunction);
      const result = await callbacks.run(token);

      expect(token).toBe("cb_test_token_123");
      expect(result).toEqual({ success: true });
    });

    it("should create and delete callback", async () => {
      const testFunction = async function myCallback() {
        return "result";
      };

      const token = await callbacks.create(testFunction);
      await callbacks.delete(token);

      expect(mockCallbacksStub.delete).toHaveBeenCalledWith(token);
    });
  });
});
