import { type Activity, type Priority } from "./plot";

/**
 * Base class for all agents.
 *
 * Agents are activated in a Plot priority and have access to that priority and all
 * its descendants.
 *
 * Override method to handle events.
 *
 * @example
 * ```typescript
 * class FlatteringAgent extends Agent {
 *  private plot: Plot;
 *
 *  constructor(tools: Tools) {
 *    super();
 *    this.plot = tools.get(Plot);
 *  }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Initialize agent for the given priority
 *     await this.plot.createActivity({
 *      type: ActivityType.Note,
 *      note: "Hello, good looking!",
 *    });
 *   }
 *
 *   async activity(activity: Activity) {
 *     // Process new activity
 *   }
 * }
 * ```
 */
export abstract class Agent {
  /**
   * Called when the agent is activated for a specific priority.
   *
   * This method should contain initialization logic such as setting up
   * initial activities, configuring webhooks, or establishing external connections.
   *
   * @param _priority - The priority context containing the priority ID
   * @returns Promise that resolves when activation is complete
   */
  activate(_priority: Pick<Priority, "id">): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when an activity needs to be processed by this agent.
   *
   * This method is invoked when activities are routed to this agent,
   * either through explicit assignment or through filtering rules.
   *
   * @param _activity - The activity to process
   * @returns Promise that resolves when processing is complete
   */
  activity(_activity: Activity): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Dynamically calls a method on this agent instance. This is used by the platform for callbacks
   * and isn't intended for direct use.
   *
   * @param name - The name of the method to call
   * @param args - Arguments to pass to the method
   * @param context - Additional context data for the method call
   * @returns Promise resolving to the method's return value
   * @throws {string} When the specified method is not found
   */
  call(name: string, args: any, context: any): Promise<any> {
    const fn = (this as any)[name];
    if (typeof fn !== "function") {
      return Promise.reject(`Callback function '${name}' not found on agent.`);
    }
    return fn.call(this, args, context);
  }
}

/**
 * Interface for tools. Tools should extend Tool. Several built-in tools
 * implement this interface directly since they're securely proxied
 * outside the agent runtime.
 */
export abstract class ITool {
  static readonly id: string;

  /**
   * Dynamically calls a method on this tool instance.
   *
   * @param name - The name of the method to call
   * @param args - Arguments to pass to the method
   * @param context - Additional context data for the method call
   * @returns Promise resolving to the method's return value
   */
  abstract call(name: string, args: any, context: any): Promise<any>;
}

export type IToolConstructor<T extends ITool> = {
  new (tools: Tools): T;
  readonly id: string;
};

/**
 * Base class for regular tools.
 *
 * Regular tools run in isolation and can only access other tools declared
 * in their tool.json dependencies. They are ideal for external API integrations
 * and reusable functionality that doesn't require Plot's internal infrastructure.
 *
 * @example
 * ```typescript
 * class GoogleCalendarTool extends Tool {
 *   constructor(protected tools: Tools) {
 *     super();
 *     this.auth = tools.get(Auth);
 *   }
 *
 *   async getCalendars() {
 *     // Implementation
 *   }
 * }
 * ```
 */
export abstract class Tool implements ITool {
  /**
   * Dynamically calls a method on this tool instance.
   *
   * This method enables external systems to invoke tool methods by name,
   * which is commonly used for callback mechanisms and cross-tool communication.
   *
   * @param name - The name of the method to call
   * @param args - Arguments to pass to the method
   * @param context - Additional context data for the method call
   * @returns Promise resolving to the method's return value
   * @throws {string} When the specified method is not found
   */
  call(name: string, args: any, context: any): Promise<any> {
    const fn = (this as any)[name];
    if (typeof fn !== "function") {
      return Promise.reject(`Callback function '${name}' not found on tool.`);
    }
    return fn.call(this, args, context);
  }
}

/**
 * Interface for accessing tool dependencies.
 *
 * This interface provides type-safe access to tools that have been declared
 * as dependencies in the agent.json or tool.json configuration files.
 */
export interface Tools {
  /**
   * Retrieves a tool instance by its class reference.
   *
   * @template T - The expected type of the tool
   * @param ToolClass - The tool class reference with a static id property
   * @returns The tool instance
   * @throws When the tool is not found or not properly configured
   */
  get<T extends ITool>(ToolClass: IToolConstructor<T>): T;
}

export type ToolDependencies = {
  id: string;
  tool?: Tool;
  constructor?: IToolConstructor<any>;
  dependencies?: ToolDependencies[];
};

export class CachedTools implements Tools {
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

    const tools = new CachedTools(dependencies);
    return new constructor(tools);
  }
}

/**
 * Tracks tool dependencies by intercepting Tools.get() calls during construction.
 * Used to dynamically discover agent and tool dependencies without static registries.
 */
class DependencyTracker implements Tools {
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

export class AgentWrapper {
  constructor(private builder: (tools: Tools) => Agent) {}

  private buildAgent(dependencies: ToolDependencies[]) {
    const tools = new CachedTools(dependencies);
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
      const tools = new CachedTools(tool.dependencies ?? []);
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
  AgentClass: new (tools: Tools) => T
) {
  return class extends AgentWrapper {
    constructor() {
      super((tools) => new AgentClass(tools));
    }
  };
}
