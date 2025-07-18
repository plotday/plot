import type { Activity } from "@plotday/agents/src/priority";

import { WorkerEntrypoint } from "cloudflare:workers";
import { createClient } from "@plotday/db";
import { createAgent } from "@plotday/agents";
import { Priority } from "../../api/src/priority";

export type Bindings = {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
};

export default class extends WorkerEntrypoint<Bindings> {
  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  async activate(agentId: string, priority: Priority, config: any = {}) {
    const supabase = createClient(this.env.SUPABASE_URL, this.env.SUPABASE_SERVICE_KEY);
    const agent = await createAgent(agentId);
    await agent.activate(priority, config);
  }

  async activity(agentId: string, activity: Activity, priority: Priority, config: any = {}) {
    const agent = await createAgent(agentId);
    return await agent.activity(activity, priority, config);
  }
}
