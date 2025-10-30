import type { Store as IStore } from "@plotday/agent/tools/store";

import { type Storage } from "../../state/storage";
import { Tool } from "./tool";
import { validateSerializable } from "./validation";

export class Store extends Tool implements IStore {
  private storage: DurableObjectStub<Storage>;

  constructor(options: {
    storage: DurableObjectNamespace<Storage>;
    priorityAgentId: string;
    path: string[];
  }) {
    super();
    // Remove final element (this tool's ID) from path
    const toolPath = options.path.slice(0, -1);
    const storageId = options.storage.idFromName(
      `${options.priorityAgentId}:${toolPath.join(":")}`
    );
    this.storage = options.storage.get(storageId);
  }

  async get<T>(key: string) {
    const value = await this.storage.get(key);
    try {
      if (value === null) return null;
      return JSON.parse(value) as T;
    } catch {
      // If JSON parsing fails, return the raw string as T
      return value as T;
    }
  }

  async set<T>(key: string, value: T) {
    // Validate that the value doesn't contain functions or other non-serializable types
    validateSerializable(`store value for key "${key}"`, value);

    const serializedValue = JSON.stringify(value);
    return await this.storage.set(key, serializedValue);
  }

  async clear(key: string) {
    await this.storage.clear(key);
  }

  async clearAll() {
    await this.storage.clearAll();
  }
}
