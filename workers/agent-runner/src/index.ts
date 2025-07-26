import { WorkerEntrypoint } from "cloudflare:workers";

import type { Activity, Plot } from "@plotday/agents";
import { createAgent } from "@plotday/agents";

export type Bindings = {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
};

export default class extends WorkerEntrypoint<Bindings> {
  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  async activate(agentId: string, plot: Plot, config: any = {}) {
    const agent = await createAgent(agentId);
    await agent.activate(plot, config);
  }

  async activity(
    agentId: string,
    activity: Activity,
    plot: Plot,
    config: any = {}
  ) {
    const agent = await createAgent(agentId);
    return await agent.activity(plot, config, activity);
  }
}
