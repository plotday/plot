import type { Agent, Tools as ITools } from "@plotday/sdk";

export type ToolDependency = {
  id: string;
  tool?: string;
  account?: string;
};

export type ToolForDependency = {
  tool?: unknown;
  dependency: ToolDependency;
};

class Tools implements ITools {
  private tools: Map<string, unknown>;

  constructor(tools: ToolForDependency[], tool?: string, account?: string) {
    this.tools = tools.reduce((map, dep) => {
      if (
        dep.dependency.tool === tool &&
        dep.dependency.account === account &&
        dep.tool
      ) {
        map.set(dep.dependency.id, dep.tool);
      }
      return map;
    }, new Map<string, unknown>());
  }

  get<T>(id: string): T {
    return this.tools.get(id) as T;
  }
}

export async function createAgent(
  id: string,
  deps: ToolForDependency[]
): Promise<Agent> {
  const tools = new Tools(deps);
  switch (id) {
    case "plot": {
      const agent = await import("../agents/plot/src");
      return new agent.default(tools);
    }
    case "chat": {
      const agent = await import("../agents/chat/src");
      return new agent.default(tools);
    }
    default:
      throw new Error(`Unknown agent: ${id}`);
  }
}
