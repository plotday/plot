import { WorkerEntrypoint } from "cloudflare:workers";

import { type ToolForDependency, createAgent } from "@plotday/agents/framework";
import type { Activity, Priority } from "@plotday/agents/sdk";

export type Bindings = {};

export default class extends WorkerEntrypoint<Bindings> {
  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  async activate(
    agentId: string,
    tools: ToolForDependency[],
    priority: Pick<Priority, "id">
  ) {
    const agent = await createAgent(agentId, tools);
    return agent.activate(priority);
  }

  async activity(
    agentId: string,
    tools: ToolForDependency[],
    activity: Activity
  ) {
    const agent = await createAgent(agentId, tools);
    return agent.activity(activity);
  }
}
