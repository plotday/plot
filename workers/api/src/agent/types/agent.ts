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
   * Dynamically calls a method on this tool instance. This is used by the platform for callbacks.
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
