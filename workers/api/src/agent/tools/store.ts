import { type Storage } from "../../state/storage";
import type { Store as IStore } from "@plotday/sdk/tools/store";
import { Tool } from "./tool";

export class Store extends Tool implements IStore {
  private storage: DurableObjectStub<Storage>;

  constructor({
    storage,
    priorityAgentId,
    path,
  }: {
    storage: DurableObjectNamespace<Storage>;
    priorityAgentId: string;
    path: string[];
  }) {
    super();
    // Remove final element (this tool's ID) from path
    const toolPath = path.slice(0, -1);
    const storageId = storage.idFromName(
      `${priorityAgentId}:${toolPath.join(":")}`
    );
    this.storage = storage.get(storageId);
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
    const serializedValue = JSON.stringify(value);
    return await this.storage.set(key, serializedValue);
  }

  async clear(key: string) {
    try {
      await this.storage.clear(key);
    } catch (error) {
      console.error("Store remove error:", error);
      throw error;
    }
  }

  async clearAll() {
    try {
      await this.storage.clearAll();
    } catch (error) {
      console.error("Store remove error:", error);
      throw error;
    }
  }
}
