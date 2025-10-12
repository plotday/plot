import { WorkerEntrypoint } from "cloudflare:workers";

import type {
  Activity,
  Agent,
  ITool,
  IToolConstructor,
  Tools as ITools,
  Priority,
  Tool,
} from "../sdk";

export type ToolDependencies = {
  id: string;
  tool?: Tool;
  constructor?: IToolConstructor<any>;
  dependencies?: ToolDependencies[];
};

class Tools implements ITools {
  private cache: Map<string, Tool> = new Map();

  constructor(private dependencies: ToolDependencies[]) {}

  get<T extends ITool>(ToolClass: IToolConstructor<T>): T {
    return this.getById(ToolClass.id);
  }

  getById<T extends ITool>(id: string): T {
    // Check cache first
    if (this.cache.has(id)) {
      return this.cache.get(id) as T;
    }

    // Find the dependency
    const dep = this.dependencies.find((d) => d.id === id);
    if (!dep) {
      throw new Error(`Tool not found: ${id}`);
    }

    // Use pre-built tool if available (for built-in tools)
    if (dep.tool) {
      this.cache.set(id, dep.tool);
      return dep.tool as T;
    }

    // Otherwise construct it lazily using the constructor from the dependency
    const tool = this.constructTool(
      id,
      dep.dependencies ?? [],
      dep.constructor
    );
    this.cache.set(id, tool);
    return tool as T;
  }

  private constructTool(
    id: string,
    dependencies: ToolDependencies[],
    constructor?: IToolConstructor<any>
  ): Tool {
    if (!constructor) {
      throw new Error(
        `No constructor available for tool: ${id}. Tool must be imported and used via tools.get() to be auto-discovered.`
      );
    }

    const tools = new Tools(dependencies);
    return new constructor(tools);
  }
}

/**
 * Tracks tool dependencies by intercepting Tools.get() calls during construction.
 * Used to dynamically discover agent and tool dependencies without static registries.
 */
class DependencyTracker implements ITools {
  private toolRequests = new Map<
    string,
    {
      constructor: IToolConstructor<any>;
      nestedTracker: DependencyTracker;
    }
  >();

  get<T extends ITool>(ToolClass: IToolConstructor<T>): T {
    const toolId = ToolClass.id;

    // Create nested tracker to capture this tool's dependencies
    const nestedTracker = new DependencyTracker();

    // Try to construct the tool to trigger its dependency requests
    try {
      new ToolClass(nestedTracker);
    } catch (e) {
      // Expected to fail - we're just capturing dependency requests
    }

    // Record this tool request and its nested dependencies
    this.toolRequests.set(toolId, {
      constructor: ToolClass,
      nestedTracker,
    });

    // Return mock object (construction will likely fail later, but we don't care)
    return {} as T;
  }

  /**
   * Builds the dependency tree from tracked tool requests.
   * Recursively processes nested dependencies and includes constructors.
   */
  buildDependencyTree(): ToolDependencies[] {
    const result: ToolDependencies[] = [];

    for (const [id, { constructor, nestedTracker }] of this.toolRequests) {
      result.push({
        id,
        constructor,
        // Recursively build dependencies for this tool
        dependencies: nestedTracker.buildDependencyTree(),
      });
    }

    return result;
  }
}

export class AgentWrapper extends WorkerEntrypoint<{}> {
  public builder: (tools: ITools) => Agent;
  public ctx: ExecutionContext;
  public env: {};

  constructor(
    ctx: ExecutionContext,
    env: {},
    builder: (tools: ITools) => Agent
  ) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
    this.builder = builder;
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  public buildAgent(dependencies: ToolDependencies[]) {
    const tools = new Tools(dependencies);
    return this.builder(tools);
  }

  async activate(
    dependencies: ToolDependencies[],
    priority: Pick<Priority, "id">
  ) {
    const agent = this.buildAgent(dependencies);
    return agent.activate(priority);
  }

  async activity(dependencies: ToolDependencies[], activity: Activity) {
    const agent = this.buildAgent(dependencies);
    return agent.activity(activity);
  }

  async call(
    dependencies: ToolDependencies[],
    functionName: string,
    args: any,
    context: any
  ) {
    const target = this.buildAgent(dependencies);
    return await target.call(functionName, args, context);
  }

  async callTool(
    tool: ToolDependencies,
    functionName: string,
    args: any,
    context: any
  ) {
    // Use pre-built tool if available, otherwise construct lazily
    let target: Tool;
    if (tool.tool) {
      target = tool.tool;
    } else {
      const tools = new Tools(tool.dependencies ?? []);
      target = tools.getById(tool.id);
    }
    return await target.call(functionName, args, context);
  }

  /**
   * Dynamically discovers all tool dependencies for this agent.
   *
   * Constructs the agent with a dependency tracker to intercept all Tools.get() calls,
   * then recursively builds the complete dependency tree. This enables dynamic dependency
   * resolution without requiring static configuration files.
   *
   * @returns Array of tool dependencies with their nested dependencies
   */
  getDependencies(): ToolDependencies[] {
    const tracker = new DependencyTracker();

    try {
      // Call builder to trigger agent construction
      // This will cause the agent to call tools.get() for its dependencies
      this.builder(tracker);
    } catch (e) {
      // Expected to fail since we're passing mock tools
      // We only care about what was requested, not actual execution
    }

    // Build and return the complete dependency tree
    return tracker.buildDependencyTree();
  }
}

export function createAgent<T extends Agent>(
  AgentClass: new (tools: ITools) => T
) {
  return class extends AgentWrapper {
    constructor(ctx: ExecutionContext, env: {}) {
      super(ctx, env, (tools) => new AgentClass(tools));
    }
  };
}
