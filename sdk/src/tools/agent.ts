import { type Callback, ITool } from "..";

/**
 * Represents a log entry from an agent execution.
 */
export type Log = {
  timestamp: Date;
  environment: "personal" | "private" | "review" | "public";
  severity: "log" | "error" | "warn" | "info";
  message: string;
};

/**
 * Built-in tool for managing agents and deployments.
 *
 * The Agent tool provides agents with the ability to create agent IDs
 * and programmatically deploy agents.
 *
 * @example
 * ```typescript
 * class AgentBuilderAgent extends Agent {
 *   private agent: AgentManager;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.agent = tools.get(AgentTool);
 *   }
 *
 *   async activate() {
 *     const agentId = await this.agent.create();
 *     // Display agent ID to user
 *   }
 * }
 * ```
 */
export abstract class AgentManager extends ITool {
  /**
   * Creates a new agent ID and grants access to people in the current priority.
   *
   * @returns Promise resolving to the generated agent ID
   * @throws When agent creation fails
   *
   * @example
   * ```typescript
   * const agentId = await agent.create();
   * console.log(`Your agent ID: ${agentId}`);
   * ```
   */
  abstract create(): Promise<string>;

  /**
   * Deploys an agent programmatically.
   *
   * This method provides the same functionality as the plot agent deploy CLI
   * command, but can be called from within an agent. It does not bundle the
   * agent code - the module code must be provided pre-bundled.
   *
   * @param options - Deployment configuration
   * @param options.agentId - Agent ID for deployment
   * @param options.module - Pre-bundled agent module code
   * @param options.environment - Target environment (defaults to "personal")
   * @param options.name - Optional agent name (required for first deploy)
   * @param options.description - Optional agent description (required for first deploy)
   * @returns Promise resolving to deployment result with version
   * @throws When deployment fails or user lacks access
   *
   * @example
   * ```typescript
   * const result = await agent.deploy({
   *   agentId: 'abc-123-...',
   *   module: 'export default class MyAgent extends Agent {...}',
   *   environment: 'personal',
   *   name: 'My Agent',
   *   description: 'Does something cool'
   * });
   * console.log(`Deployed version ${result.version}`);
   * ```
   */
  abstract deploy(_options: {
    agentId: string;
    module: string;
    environment?: "personal" | "private" | "review";
    name: string;
    description?: string;
  }): Promise<{
    version: string;
  }>;

  /**
   * Subscribes to logs from an agent.
   *
   * This method registers a callback to receive batches of logs from agent executions.
   * The callback will be invoked with an array of logs whenever new logs are captured
   * from the agent's console output.
   *
   * @param agentId - Agent ID (root ID) to watch logs for
   * @param callback - Callback token created via CallbackTool that will receive log batches
   * @returns Promise that resolves when the subscription is created
   * @throws When subscription fails
   *
   * @example
   * ```typescript
   * // Create agent and callback
   * const agentId = await this.agent.create();
   * const callback = await this.callback.create("onLogs");
   *
   * // Subscribe to logs
   * await this.agent.watchLogs(agentId, callback);
   *
   * // Implement handler
   * async onLogs(logs: Log[]) {
   *   for (const log of logs) {
   *     console.log(`[${log.environment}] ${log.severity}: ${log.message}`);
   *   }
   * }
   * ```
   */
  abstract watchLogs(_agentId: string, _callback: Callback): Promise<void>;
}
