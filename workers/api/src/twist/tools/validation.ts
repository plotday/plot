/**
 * Utilities for validating values before serialization or storage
 */

export type NonSerializableInfo = {
  path: string;
  type: string;
  value?: any;
};

/**
 * Checks if a value can be safely JSON-serialized
 */
export function isSerializable(value: any): boolean {
  try {
    JSON.stringify(value);
    return true;
  } catch {
    return false;
  }
}

/**
 * Finds the first non-serializable property in a value and returns its path
 * Returns null if the value is serializable
 */
export function findNonSerializable(
  value: any,
  path: string = "value"
): NonSerializableInfo | null {
  // Check for function
  if (typeof value === "function") {
    return {
      path,
      type: "function",
      value: value.name || "<anonymous function>",
    };
  }

  // Check for symbol
  if (typeof value === "symbol") {
    return {
      path,
      type: "symbol",
      value: value.toString(),
    };
  }

  // Check for undefined (not serializable in JSON)
  if (value === undefined) {
    return {
      path,
      type: "undefined",
    };
  }

  // Check for BigInt (not serializable in JSON)
  if (typeof value === "bigint") {
    return {
      path,
      type: "bigint",
      value: value.toString(),
    };
  }

  // Check for special objects that might have RPC properties
  if (value !== null && typeof value === "object") {
    // Check for circular references by attempting to stringify
    try {
      JSON.stringify(value);
    } catch (error) {
      if (error instanceof Error && error.message.includes("circular")) {
        return {
          path,
          type: "circular reference",
        };
      }
      // Could be an RPC stub or other non-serializable object
      return {
        path,
        type: "non-serializable object",
        value: value.constructor?.name || typeof value,
      };
    }

    // Recursively check array elements
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        const result = findNonSerializable(value[i], `${path}[${i}]`);
        if (result) return result;
      }
    }
    // Recursively check object properties
    else {
      for (const key of Object.keys(value)) {
        const result = findNonSerializable(
          value[key],
          path === "value" ? key : `${path}.${key}`
        );
        if (result) return result;
      }
    }
  }

  return null;
}

/**
 * Creates a detailed error message for non-serializable values
 */
export function createSerializationError(
  operation: string,
  info: NonSerializableInfo
): Error {
  let message = `Cannot ${operation}: `;

  if (info.type === "function") {
    message += `Found function at path "${info.path}".\n\n`;
    message += `❌ DO NOT store functions directly:\n`;
    message += `   await this.tools.store.set("key", ${
      info.value || "myFunction"
    });\n\n`;
    message += `✅ Instead, create a callback token first:\n`;
    message += `   const token = await this.callback(this.${
      info.value || "myFunction"
    });\n`;
    message += `   await this.tools.store.set("key", token);\n\n`;
    message += `Then later, execute the callback:\n`;
    message += `   const token = await this.tools.store.get("key");\n`;
    message += `   await this.run(token, args);`;
  } else if (info.type === "symbol") {
    message += `Found symbol at path "${info.path}": ${info.value}\n`;
    message += `Symbols cannot be serialized to JSON. Consider using a string instead.`;
  } else if (info.type === "undefined") {
    message += `Found undefined value at path "${info.path}".\n`;
    message += `Use null instead of undefined for values that need to be stored.`;
  } else if (info.type === "bigint") {
    message += `Found BigInt at path "${info.path}": ${info.value}\n`;
    message += `BigInt values cannot be serialized to JSON. Consider converting to a string.`;
  } else if (info.type === "circular reference") {
    message += `Found circular reference at path "${info.path}".\n`;
    message += `Objects with circular references cannot be serialized.`;
  } else {
    message += `Found non-serializable ${info.type} at path "${info.path}".\n`;
    if (info.value) {
      message += `Type: ${info.value}`;
    }
  }

  return new Error(message);
}

/**
 * Validates that a value can be serialized, throwing a helpful error if not
 */
export function validateSerializable(operation: string, value: any): void {
  const nonSerializable = findNonSerializable(value);
  if (nonSerializable) {
    throw createSerializationError(operation, nonSerializable);
  }
}

/**
 * Removes trailing undefined values from an array.
 * Preserves undefined values in the middle of the array.
 *
 * This is useful for callback arguments where trailing optional parameters
 * can be omitted. In JavaScript, f(1, 2, undefined) is equivalent to f(1, 2)
 * for optional parameters.
 *
 * Examples:
 *   [1, 2, undefined, undefined] -> [1, 2]
 *   [1, undefined, 3] -> [1, undefined, 3]
 *   [undefined, undefined] -> []
 *   [] -> []
 */
export function stripTrailingUndefined(args: any[]): any[] {
  let lastDefinedIndex = -1;

  for (let i = args.length - 1; i >= 0; i--) {
    if (args[i] !== undefined) {
      lastDefinedIndex = i;
      break;
    }
  }

  return args.slice(0, lastDefinedIndex + 1);
}
