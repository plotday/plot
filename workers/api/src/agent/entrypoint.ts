import { WorkerEntrypoint } from "cloudflare:workers";

import { type ToolDependencies } from "../agent/types/agent";
import { type Activity, type Priority } from "../agent/types/plot";

const MODULE = `
import { WorkerEntrypoint } from "cloudflare:workers";

import Agent from "agent.js";

export default class extends WorkerEntrypoint {
  async fetch() {
    return new Response("OK");
  }

  async activate(
    dependencies,
    priority,
  ) {
    const agent = new Agent();
    return agent.activate(dependencies, priority);
  }

  async activity(dependencies, activity) {
    const agent = new Agent();
    return agent.activity(dependencies, activity);
  }

  async call(
    dependencies,
    functionName,
    args,
    context,
  ) {
    const agent = new Agent();
    return agent.call(dependencies, functionName, args, context);
  }

  async callTool(
    tool,
    functionName,
    args,
    context,
  ) {
    const agent = new Agent();
    return agent.callTools(tool, functionName, args, context);
  }

  getDependencies() {
    const agent = new Agent();
    return agent.getDependencies();
  }
}
`;

export class AgentEntrypoint extends WorkerEntrypoint {
  static Module = MODULE;

  async fetch() {
    return new Response("OK");
  }

  async activate(
    _dependencies: ToolDependencies[],
    _priority: Pick<Priority, "id">
  ) {}

  async activity(_dependencies: ToolDependencies[], _activity: Activity) {}

  async call(
    _dependencies: ToolDependencies[],
    _functionName: string,
    _args: any,
    _context: any
  ): Promise<any> {}

  async callTool(
    _tool: ToolDependencies,
    _functionName: string,
    _args: any,
    _context: any
  ): Promise<any> {
    return null;
  }

  getDependencies(): ToolDependencies[] {
    return [];
  }
}

export default AgentEntrypoint;
