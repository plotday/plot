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

  async activate(agentId: string, priorityId: string) {
    const supabase = createClient(this.env.SUPABASE_URL, this.env.SUPABASE_SERVICE_KEY);
    const priority = new Priority(supabase, priorityId);
    const agent = await createAgent(agentId);
    await agent.activate(priority);
  }
}
