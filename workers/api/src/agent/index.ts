import { type AgentWrapper } from "@plotday/agent";

import { type Bindings } from "../env";

export * from "./management";
export * from "./tools";

export type AgentFactory = (id: string) => AgentWrapper;

export function agentFactory(env: Bindings): AgentFactory {
  return (id: string) => {
    const name = `AGENT_${id.toUpperCase().replace("-", "_")}`;
    if (name in (env as any)) {
      return (env as any)[name] as unknown as AgentWrapper;
    } else if (env.AGENTS) {
      return env.AGENTS.get(id) as unknown as AgentWrapper;
    } else {
      throw new Error(`No agent found for ID: ${id}`);
    }
  };
}
