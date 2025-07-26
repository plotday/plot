import type { Agent } from "./types";

export async function createAgent(id: string): Promise<Agent> {
  switch (id) {
    case "plot": {
      const agent = await import("./plot");
      return new agent.default();
    }
    case "chat": {
      const agent = await import("./chat");
      return new agent.default();
    }
    default:
      throw new Error(`Unknown agent: ${id}`);
  }
}
