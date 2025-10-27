import { type Callback, ITool } from "..";

/**
 * Agent source code structure containing dependencies and source files.
 */
export interface AgentSource {
  /**
   * Package dependencies with version specifiers
   * @example { "@plotday/sdk": "workspace:^", "@plotday/tool-google-calendar": "^1.0.0" }
   */
  dependencies: Record<string, string>;

  /**
   * Source files with their content
   * Must include "index.ts" as the entry point
   * @example { "index.ts": "export default class MyAgent extends Agent {...}" }
   */
  files: Record<string, string>;
}

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
 * Agent permissions returned after deployment.
 * Nested structure mapping domains to entities to permission flags.
 *
 * Format: { domain: { entity: flags[] } }
 * - domain: Tool name (e.g., "network", "plot")
 * - entity: Domain-specific identifier (e.g., URL pattern, resource type)
 * - flags: Array of permission flags ("read", "write", "update", "use")
 *
 * @example
 * ```typescript
 * {
 *   "network": {
 *     "https://api.example.com/*": ["use"],
 *     "https://googleapis.com/*": ["use"]
 *   },
 *   "plot": {
 *     "activity:mentioned": ["read", "write", "update"],
 *     "priority": ["read", "write", "update"]
 *   }
 * }
 * ```
 */
export type AgentPermissions = Record<string, Record<string, string[]>>;

/**
 * Built-in tool for managing agents and deployments.
 *
 * The Agent tool provides agents with the ability to create agent IDs
 * and programmatically deploy agents.
 *
 * @example
 * ```typescript
 * class AgentBuilderAgent extends Agent {
 *   build(build: ToolBuilder) {
 *    return {
 *      agents: build.get(Agents)
 *    }
 *   }
 *
 *   async activate() {
 *     const agentId = await this.tools.agents.create();
 *     // Display agent ID to user
 *   }
 * }
 * ```
 */
export abstract class Agents extends ITool {
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
   * Generates agent source code from a specification using AI.
   *
   * This method uses Claude AI to generate TypeScript source code and dependencies
   * from a markdown specification. The generated source is validated by attempting
   * to build it, with iterative error correction (up to 3 attempts).
   *
   * @param spec - Markdown specification describing the agent functionality
   * @returns Promise resolving to agent source (dependencies and files)
   * @throws When generation fails after maximum attempts
   *
   * @example
   * ```typescript
   * const source = await agent.generate(`
   * # Calendar Sync Agent
   *
   * This agent syncs Google Calendar events to Plot activities.
   *
   * ## Features
   * - Authenticate with Google
   * - Sync calendar events
   * - Create activities from events
   * `);
   *
   * // source.dependencies: { "@plotday/sdk": "workspace:^", ... }
   * // source.files: { "index.ts": "export default class..." }
   * ```
   */
  abstract generate(_spec: string): Promise<AgentSource>;

  /**
   * Deploys an agent programmatically.
   *
   * This method provides the same functionality as the plot agent deploy CLI
   * command, but can be called from within an agent. Accepts either:
   * - A pre-bundled module (JavaScript code)
   * - A source object (dependencies + files) which is built in a sandbox
   *
   * @param options - Deployment configuration
   * @param options.agentId - Agent ID for deployment
   * @param options.module - Pre-bundled agent module code (mutually exclusive with source)
   * @param options.source - Agent source code with dependencies (mutually exclusive with module)
   * @param options.environment - Target environment (defaults to "personal")
   * @param options.name - Optional agent name (required for first deploy)
   * @param options.description - Optional agent description (required for first deploy)
   * @param options.dryRun - If true, validates without deploying (returns errors if any)
   * @returns Promise resolving to deployment result with version and optional errors
   * @throws When deployment fails or user lacks access
   *
   * @example
   * ```typescript
   * // Deploy with a module
   * const result = await agent.deploy({
   *   agentId: 'abc-123-...',
   *   module: 'export default class MyAgent extends Agent {...}',
   *   environment: 'personal',
   *   name: 'My Agent',
   *   description: 'Does something cool'
   * });
   * console.log(`Deployed version ${result.version}`);
   *
   * // Deploy with source
   * const source = await agent.generate(spec);
   * const result = await agent.deploy({
   *   agentId: 'abc-123-...',
   *   source,
   *   environment: 'personal',
   *   name: 'My Agent',
   * });
   *
   * // Validate with dryRun
   * const result = await agent.deploy({
   *   agentId: 'abc-123-...',
   *   source,
   *   dryRun: true,
   * });
   * if (result.errors?.length) {
   *   console.error('Build errors:', result.errors);
   * }
   * ```
   */
  abstract deploy(
    _options: {
      agentId: string;
      environment?: "personal" | "private" | "review";
      name?: string;
      description?: string;
      dryRun?: boolean;
    } & (
      | {
          module: string;
        }
      | {
          source: AgentSource;
        }
    )
  ): Promise<{
    version: string;
    permissions: AgentPermissions;
    errors?: string[];
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
