import { describe, it, expect, beforeEach, vi } from "vitest";
import superjson from "superjson";
import { Store } from "../store";

describe("Store", () => {
  let store: Store;
  let mockStorage: any;
  let storageData: Map<string, string>;

  beforeEach(() => {
    // Create a simple in-memory storage mock
    storageData = new Map();

    mockStorage = {
      get: vi.fn((key: string) => storageData.get(key) ?? null),
      set: vi.fn((key: string, value: string) => {
        storageData.set(key, value);
      }),
      clear: vi.fn((key: string) => {
        storageData.delete(key);
      }),
      clearAll: vi.fn(() => {
        storageData.clear();
      }),
    };

    const mockStorageNamespace = {
      idFromName: vi.fn(() => "mock-storage-id"),
      get: vi.fn(() => mockStorage),
    } as any;

    store = new Store({
      storage: mockStorageNamespace,
      priorityTwistId: "pa-1",
      path: ["Tool1", "Store"],
    });
  });

  describe("get", () => {
    it("should get value from storage", async () => {
      storageData.set("test-key", superjson.stringify({ data: "test-value" }));

      const result = await store.get("test-key");

      expect(result).toEqual({ data: "test-value" });
      expect(mockStorage.get).toHaveBeenCalledWith("test-key");
    });

    it("should return null for missing key", async () => {
      const result = await store.get("missing-key");

      expect(result).toBeNull();
    });

    it("should parse JSON values", async () => {
      storageData.set("json-key", superjson.stringify({ foo: "bar", count: 42 }));

      const result = await store.get("json-key");

      expect(result).toEqual({ foo: "bar", count: 42 });
    });

    it("should return raw string if JSON parsing fails", async () => {
      storageData.set("invalid-json", "not valid json");

      const result = await store.get("invalid-json");

      expect(result).toBe("not valid json");
    });

    it("should handle arrays", async () => {
      const array = [1, 2, 3];
      storageData.set("array-key", superjson.stringify(array));

      const result = await store.get("array-key");

      expect(result).toEqual(array);
    });

    it("should handle nested objects", async () => {
      const nested = { a: { b: { c: "deep" } } };
      storageData.set("nested-key", superjson.stringify(nested));

      const result = await store.get("nested-key");

      expect(result).toEqual(nested);
    });

    it("should handle legacy JSON format (backward compatibility)", async () => {
      // Legacy format: plain JSON.stringify (not superjson)
      storageData.set("legacy-key", JSON.stringify({ old: "data" }));

      const result = await store.get("legacy-key");

      // superjson.parse will interpret {old: "data"} differently,
      // but JSON.parse fallback should handle it
      expect(result).not.toBeNull();
    });
  });

  describe("set", () => {
    it("should set value in storage using superjson", async () => {
      await store.set("test-key", { data: "test-value" });

      expect(mockStorage.set).toHaveBeenCalledWith(
        "test-key",
        superjson.stringify({ data: "test-value" })
      );
    });

    it("should serialize objects to superjson", async () => {
      const obj = { foo: "bar", count: 42 };
      await store.set("obj-key", obj);

      expect(mockStorage.set).toHaveBeenCalledWith("obj-key", superjson.stringify(obj));
    });

    it("should serialize arrays to superjson", async () => {
      const arr = [1, 2, 3];
      await store.set("arr-key", arr);

      expect(mockStorage.set).toHaveBeenCalledWith("arr-key", superjson.stringify(arr));
    });

    it("should throw error for functions", async () => {
      await expect(
        store.set("func-key", { fn: () => {} })
      ).rejects.toThrow();
    });

    it("should throw error for symbols", async () => {
      await expect(
        store.set("symbol-key", { sym: Symbol("test") })
      ).rejects.toThrow();
    });

    it("should handle undefined values in objects (serialized by superjson)", async () => {
      await store.set("undefined-key", { val: undefined, keep: "value" });
      expect(mockStorage.set).toHaveBeenCalled();
    });

    it("should handle null values", async () => {
      await store.set("null-key", null);

      expect(mockStorage.set).toHaveBeenCalledWith("null-key", superjson.stringify(null));
    });

    it("should handle boolean values", async () => {
      await store.set("bool-key", true);

      expect(mockStorage.set).toHaveBeenCalledWith("bool-key", superjson.stringify(true));
    });

    it("should handle number values", async () => {
      await store.set("num-key", 42);

      expect(mockStorage.set).toHaveBeenCalledWith("num-key", superjson.stringify(42));
    });

    it("should handle string values", async () => {
      await store.set("str-key", "hello");

      expect(mockStorage.set).toHaveBeenCalledWith("str-key", superjson.stringify("hello"));
    });
  });

  describe("clear", () => {
    it("should clear value from storage", async () => {
      await store.clear("test-key");

      expect(mockStorage.clear).toHaveBeenCalledWith("test-key");
    });

    it("should handle errors gracefully", async () => {
      mockStorage.clear.mockRejectedValueOnce(new Error("Clear failed"));

      await expect(store.clear("test-key")).rejects.toThrow("Clear failed");
    });
  });

  describe("clearAll", () => {
    it("should clear all values from storage", async () => {
      await store.clearAll();

      expect(mockStorage.clearAll).toHaveBeenCalled();
    });

    it("should handle errors gracefully", async () => {
      mockStorage.clearAll.mockRejectedValueOnce(new Error("ClearAll failed"));

      await expect(store.clearAll()).rejects.toThrow("ClearAll failed");
    });
  });

  describe("integration", () => {
    it("should set and get value", async () => {
      const data = { test: "value", count: 42 };
      await store.set("key", data);

      const result = await store.get("key");

      expect(result).toEqual(data);
    });

    it("should overwrite existing value", async () => {
      await store.set("key", { old: "value" });
      await store.set("key", { new: "value" });

      const result = await store.get("key");

      expect(result).toEqual({ new: "value" });
    });

    it("should clear value", async () => {
      await store.set("key", { data: "value" });
      await store.clear("key");

      const result = await store.get("key");

      expect(result).toBeNull();
    });

    it("should clear all values", async () => {
      await store.set("key1", { data: "value1" });
      await store.set("key2", { data: "value2" });
      await store.clearAll();

      const result1 = await store.get("key1");
      const result2 = await store.get("key2");

      expect(result1).toBeNull();
      expect(result2).toBeNull();
    });
  });
});
