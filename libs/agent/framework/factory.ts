import { WorkerEntrypoint } from "cloudflare:workers";

import type { Activity, Agent, Tools as ITools, Priority, Tool } from "../sdk";
import GoogleCalendarTool from "../tools/google-calendar";
import OutlookCalendarTool from "../tools/outlook-calendar";

export type ToolDependencies = {
  id: string;
  tool?: Tool;
  dependencies?: ToolDependencies[];
};

class Tools implements ITools {
  constructor(private tools: Map<string, Tool>) {}

  get<T>(id: string): T {
    const tool = this.tools.get(id);
    if (!tool) {
      throw new Error(`Tool not found: ${id}`);
    }
    return tool as T;
  }
}

async function createTool(
  id: string,
  dependencies: ToolDependencies[]
): Promise<Tool> {
  const tools = await createTools(dependencies || []);
  switch (id) {
    case "google-calendar":
      return new GoogleCalendarTool(tools);
    case "outlook-calendar":
      return new OutlookCalendarTool(tools);
    default:
      throw new Error(`Unknown tool ID: ${id}`);
  }
}

async function createTools(dependencies: ToolDependencies[]): Promise<Tools> {
  const tools = new Map<string, Tool>();
  for (const t of dependencies) {
    const tool = t.tool ?? (await createTool(t.id, t.dependencies ?? []));
    tools.set(t.id, tool);
  }
  return new Tools(tools);
}

export class AgentWrapper extends WorkerEntrypoint<{}> {
  constructor(
    ctx: ExecutionContext,
    env: {},
    private AgentClass: new (tools: Tools) => Agent
  ) {
    super(ctx, env);
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private async buildAgent(dependencies: ToolDependencies[]) {
    const tools = await createTools(dependencies);
    return new this.AgentClass(tools);
  }

  async activate(
    dependencies: ToolDependencies[],
    priority: Pick<Priority, "id">
  ) {
    const agent = await this.buildAgent(dependencies);
    return agent.activate(priority);
  }

  async activity(dependencies: ToolDependencies[], activity: Activity) {
    const agent = await this.buildAgent(dependencies);
    return agent.activity(activity);
  }

  async call(
    dependencies: ToolDependencies[],
    functionName: string,
    args: any,
    context: any
  ) {
    const target = await this.buildAgent(dependencies);
    return await target.call(functionName, args, context);
  }

  async callTool(
    tool: ToolDependencies,
    functionName: string,
    args: any,
    context: any
  ) {
    const target =
      tool.tool ?? (await createTool(tool.id, tool.dependencies ?? []));
    return await target.call(functionName, args, context);
  }
}

export function createAgent(AgentClass: new (tools: Tools) => Agent) {
  return class extends AgentWrapper {
    constructor(ctx: ExecutionContext, env: {}) {
      super(ctx, env, AgentClass);
    }
  };
}
