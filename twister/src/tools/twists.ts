import { type Callback, ITool } from "..";

/**
 * Twist source code structure containing dependencies and source files.
 */
export interface TwistSource {
  /**
   * Package dependencies with version specifiers
   * @example { "@plotday/sdk": "workspace:^", "@plotday/tool-google-calendar": "^1.0.0" }
   */
  dependencies: Record<string, string>;

  /**
   * Source files with their content
   * Must include "index.ts" as the entry point
   * @example { "index.ts": "export default class MyTwist extends Twist {...}" }
   */
  files: Record<string, string>;
}

/**
 * Represents a log entry from a twist execution.
 */
export type Log = {
  timestamp: Date;
  environment: "personal" | "private" | "review" | "public";
  severity: "log" | "error" | "warn" | "info";
  message: string;
};

/**
 * Twist permissions returned after deployment.
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
export type TwistPermissions = Record<string, Record<string, string[]>>;

/**
 * Built-in tool for managing twists and deployments.
 *
 * The Twists tool provides twists with the ability to create twist IDs
 * and programmatically deploy twists.
 *
 * @example
 * ```typescript
 * class TwistBuilderTwist extends Twist {
 *   build(build: ToolBuilder) {
 *    return {
 *      twists: build.get(Twists)
 *    }
 *   }
 *
 *   async activate() {
 *     const twistId = await this.tools.twists.create();
 *     // Display twist ID to user
 *   }
 * }
 * ```
 */
export abstract class Twists extends ITool {
  /**
   * Creates a new twist ID and grants access to people in the current priority.
   *
   * @returns Promise resolving to the generated twist ID
   * @throws When twist creation fails
   *
   * @example
   * ```typescript
   * const twistId = await twist.create();
   * console.log(`Your twist ID: ${twistId}`);
   * ```
   */
  abstract create(): Promise<string>;

  /**
   * Generates twist source code from a specification using AI.
   *
   * This method uses Claude AI to generate TypeScript source code and dependencies
   * from a markdown specification. The generated source is validated by attempting
   * to build it, with iterative error correction (up to 3 attempts).
   *
   * @param spec - Markdown specification describing the twist functionality
   * @returns Promise resolving to twist source (dependencies and files)
   * @throws When generation fails after maximum attempts
   *
   * @example
   * ```typescript
   * const source = await twist.generate(`
   * # Calendar Sync Twist
   *
   * This twist syncs Google Calendar events to Plot activities.
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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract generate(spec: string): Promise<TwistSource>;

  /**
   * Deploys a twist programmatically.
   *
   * This method provides the same functionality as the plot deploy CLI
   * command, but can be called from within a twist. Accepts either:
   * - A pre-bundled module (JavaScript code)
   * - A source object (dependencies + files) which is built in a sandbox
   *
   * @param options - Deployment configuration
   * @param options.twistId - Twist ID for deployment
   * @param options.module - Pre-bundled twist module code (mutually exclusive with source)
   * @param options.source - Twist source code with dependencies (mutually exclusive with module)
   * @param options.environment - Target environment (defaults to "personal")
   * @param options.name - Optional twist name (required for first deploy)
   * @param options.description - Optional twist description (required for first deploy)
   * @param options.dryRun - If true, validates without deploying (returns errors if any)
   * @returns Promise resolving to deployment result with version and optional errors
   * @throws When deployment fails or user lacks access
   *
   * @example
   * ```typescript
   * // Deploy with a module
   * const result = await twist.deploy({
   *   twistId: 'abc-123-...',
   *   module: 'export default class MyTwist extends Twist {...}',
   *   environment: 'personal',
   *   name: 'My Twist',
   *   description: 'Does something cool'
   * });
   * console.log(`Deployed version ${result.version}`);
   *
   * // Deploy with source
   * const source = await twist.generate(spec);
   * const result = await twist.deploy({
   *   twistId: 'abc-123-...',
   *   source,
   *   environment: 'personal',
   *   name: 'My Twist',
   * });
   *
   * // Validate with dryRun
   * const result = await twist.deploy({
   *   twistId: 'abc-123-...',
   *   source,
   *   dryRun: true,
   * });
   * if (result.errors?.length) {
   *   console.error('Build errors:', result.errors);
   * }
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract deploy(
    options: {
      twistId: string;
      environment?: "personal" | "private" | "review";
      name?: string;
      description?: string;
      dryRun?: boolean;
    } & (
      | {
          module: string;
        }
      | {
          source: TwistSource;
        }
    )
  ): Promise<{
    version: string;
    permissions: TwistPermissions;
    errors?: string[];
  }>;

  /**
   * Subscribes to logs from a twist.
   *
   * This method registers a callback to receive batches of logs from twist executions.
   * The callback will be invoked with an array of logs whenever new logs are captured
   * from the twist's console output.
   *
   * @param twistId - Twist ID (root ID) to watch logs for
   * @param callback - Callback token created via CallbackTool that will receive log batches
   * @returns Promise that resolves when the subscription is created
   * @throws When subscription fails
   *
   * @example
   * ```typescript
   * // Create twist and callback
   * const twistId = await this.twist.create();
   * const callback = await this.callback.create("onLogs");
   *
   * // Subscribe to logs
   * await this.twist.watchLogs(twistId, callback);
   *
   * // Implement handler
   * async onLogs(logs: Log[]) {
   *   for (const log of logs) {
   *     console.log(`[${log.environment}] ${log.severity}: ${log.message}`);
   *   }
   * }
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract watchLogs(twistId: string, callback: Callback): Promise<void>;
}
