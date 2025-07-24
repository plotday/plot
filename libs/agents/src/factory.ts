import type { Agent } from "./agent";

export async function createAgent(id: string): Promise<Agent> {
  switch (id) {
    case "onboarding": {
      const agent = await import("./onboarding");
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

