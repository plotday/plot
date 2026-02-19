import { describe, expect, it } from "vitest";

import {
  createSerializationError,
  findNonSerializable,
  stripTrailingUndefined,
  validateSerializable,
} from "./validation";

describe("validation utilities", () => {
  describe("findNonSerializable", () => {
    it("should return null for serializable primitives", () => {
      expect(findNonSerializable("string")).toBeNull();
      expect(findNonSerializable(123)).toBeNull();
      expect(findNonSerializable(true)).toBeNull();
      expect(findNonSerializable(null)).toBeNull();
    });

    it("should return null for serializable objects", () => {
      expect(findNonSerializable({ foo: "bar" })).toBeNull();
      expect(findNonSerializable([1, 2, 3])).toBeNull();
      expect(findNonSerializable({ nested: { value: 42 } })).toBeNull();
    });

    it("should detect functions at root level", () => {
      const result = findNonSerializable(() => {});
      expect(result).toEqual({
        path: "value",
        type: "function",
        value: "<anonymous function>",
      });
    });

    it("should detect named functions", () => {
      function myFunction() {}
      const result = findNonSerializable(myFunction);
      expect(result).toEqual({
        path: "value",
        type: "function",
        value: "myFunction",
      });
    });

    it("should detect functions in objects", () => {
      const obj = {
        name: "test",
        callback: () => {},
      };
      const result = findNonSerializable(obj);
      expect(result).toEqual({
        path: "callback",
        type: "function",
        value: "callback", // Arrow functions take the property name
      });
    });

    it("should detect functions in nested objects", () => {
      const obj = {
        data: {
          config: {
            handler: function myHandler() {},
          },
        },
      };
      const result = findNonSerializable(obj);
      expect(result).toEqual({
        path: "data.config.handler",
        type: "function",
        value: "myHandler",
      });
    });

    it("should detect functions in arrays", () => {
      const arr = [1, 2, () => {}];
      const result = findNonSerializable(arr);
      expect(result).toEqual({
        path: "value[2]",
        type: "function",
        value: "<anonymous function>",
      });
    });

    it("should detect symbols", () => {
      const sym = Symbol("test");
      const result = findNonSerializable(sym);
      expect(result?.type).toBe("symbol");
      expect(result?.path).toBe("value");
    });

    it("should allow undefined (handled by SuperJSON)", () => {
      expect(findNonSerializable(undefined)).toBeNull();
    });

    it("should allow undefined in objects (handled by SuperJSON)", () => {
      const obj = { foo: undefined };
      expect(findNonSerializable(obj)).toBeNull();
    });

    it("should detect bigint", () => {
      const result = findNonSerializable(BigInt(123));
      expect(result?.type).toBe("bigint");
      expect(result?.value).toBe("123");
    });
  });

  describe("validateSerializable", () => {
    it("should not throw for valid values", () => {
      expect(() => validateSerializable("test", "string")).not.toThrow();
      expect(() => validateSerializable("test", 123)).not.toThrow();
      expect(() => validateSerializable("test", { foo: "bar" })).not.toThrow();
      expect(() => validateSerializable("test", [1, 2, 3])).not.toThrow();
    });

    it("should throw for functions", () => {
      expect(() => validateSerializable("test operation", () => {})).toThrow();
    });

    it("should throw helpful error for functions in objects", () => {
      const obj = {
        data: {
          callback: function myCallback() {},
        },
      };

      expect(() => validateSerializable("store value", obj)).toThrow(
        /data\.callback/
      );
      expect(() => validateSerializable("store value", obj)).toThrow(
        /myCallback/
      );
    });
  });

  describe("createSerializationError", () => {
    it("should create helpful error for functions", () => {
      const error = createSerializationError("store value", {
        path: "config.handler",
        type: "function",
        value: "onComplete",
      });

      expect(error.message).toContain("config.handler");
      expect(error.message).toContain("this.callback");
      expect(error.message).toContain("DO NOT store functions directly");
      expect(error.message).toContain("create a callback token");
    });

    it("should create helpful error for symbols", () => {
      const error = createSerializationError("store value", {
        path: "mySymbol",
        type: "symbol",
        value: "Symbol(test)",
      });

      expect(error.message).toContain("mySymbol");
      expect(error.message).toContain("Symbol(test)");
      expect(error.message).toContain("cannot be serialized");
    });

    it("should create helpful error for circular references", () => {
      const error = createSerializationError("store value", {
        path: "data.circular",
        type: "circular reference",
      });

      expect(error.message).toContain("data.circular");
      expect(error.message).toContain("circular reference");
    });
  });

  describe("stripTrailingUndefined", () => {
    it("should remove trailing undefined values", () => {
      const result = stripTrailingUndefined([1, 2, undefined, undefined]);
      expect(result).toEqual([1, 2]);
    });

    it("should preserve undefined values in the middle", () => {
      const result = stripTrailingUndefined([1, undefined, 3]);
      expect(result).toEqual([1, undefined, 3]);
    });

    it("should handle all undefined values", () => {
      const result = stripTrailingUndefined([undefined, undefined]);
      expect(result).toEqual([]);
    });

    it("should handle empty array", () => {
      const result = stripTrailingUndefined([]);
      expect(result).toEqual([]);
    });

    it("should handle array with no undefined values", () => {
      const result = stripTrailingUndefined([1, 2, 3]);
      expect(result).toEqual([1, 2, 3]);
    });

    it("should handle array with single undefined at end", () => {
      const result = stripTrailingUndefined([1, 2, undefined]);
      expect(result).toEqual([1, 2]);
    });

    it("should handle array with only one undefined", () => {
      const result = stripTrailingUndefined([undefined]);
      expect(result).toEqual([]);
    });

    it("should handle complex values", () => {
      const result = stripTrailingUndefined([
        { a: 1 },
        "string",
        null,
        undefined,
        undefined,
      ]);
      expect(result).toEqual([{ a: 1 }, "string", null]);
    });

    it("should preserve null values at the end", () => {
      const result = stripTrailingUndefined([1, 2, null]);
      expect(result).toEqual([1, 2, null]);
    });

    it("should handle mixed undefined and null", () => {
      const result = stripTrailingUndefined([1, undefined, null, undefined]);
      expect(result).toEqual([1, undefined, null]);
    });
  });
});
