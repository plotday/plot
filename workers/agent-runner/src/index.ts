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

  async activate(agentId: string, plot: Plot) {
    const agent = await createAgent(agentId);
    await agent.activate(plot);
  }

  async activity(agentId: string, plot: Plot, activity: Activity) {
    const agent = await createAgent(agentId);
    return await agent.activity(plot, activity);
  }
}
