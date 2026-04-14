import type { Store as IStore } from "@plotday/twister/tools/store";
import type { Serializable } from "@plotday/twister";
import superjson from "superjson";

import { type Storage } from "../../state/storage";
import { Tool } from "./tool";
import { validateSerializable } from "./validation";

export class Store extends Tool implements IStore {
  private storage: DurableObjectStub<Storage>;

  constructor(options: {
    storage: DurableObjectNamespace<Storage>;
    twistInstanceId: string;
    path: string[];
  }) {
    super();
    // Remove final element (this tool's ID) from path
    const toolPath = options.path.slice(0, -1);
    const storageId = options.storage.idFromName(
      `${options.twistInstanceId}:${toolPath.join(":")}`
    );
    this.storage = options.storage.get(storageId);
  }

  async get<T extends Serializable>(key: string): Promise<T | null> {
    const value = await this.storage.get(key);
    if (value === null) return null;

    try {
      // Try SuperJSON first (new format)
      return superjson.parse<T>(value);
    } catch {
      try {
        // Fallback to JSON.parse for backward compatibility with legacy data
        return JSON.parse(value) as T;
      } catch {
        // Last resort: return raw string
        return value as T;
      }
    }
  }

  async set<T extends Serializable>(key: string, value: T): Promise<void> {
    // Validate that the value doesn't contain functions or other non-serializable types
    validateSerializable(`store value for key "${key}"`, value);

    const serializedValue = superjson.stringify(value);
    await this.storage.set(key, serializedValue);
  }

  async list(prefix: string): Promise<string[]> {
    const result = await this.storage.list(prefix);
    return result;
  }

  async clear(key: string) {
    await this.storage.clear(key);
  }

  async clearAll() {
    await this.storage.clearAll();
  }
}
