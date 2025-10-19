/**
 * Agent source code structure containing dependencies and source files.
 */
export interface AgentSource {
  /**
   * Human-readable display name for the agent
   * @example "Google Calendar Sync"
   */
  displayName: string;

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
 * Successful build result containing the bundled module
 */
export interface BuildSuccess {
  success: true;
  module: string;
}

/**
 * Failed build result containing error messages
 */
export interface BuildFailure {
  success: false;
  errors: string[];
}

/**
 * Result from building an agent from source
 */
export type BuildResult = BuildSuccess | BuildFailure;
