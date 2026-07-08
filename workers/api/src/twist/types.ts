/**
 * Twist source code structure containing dependencies and source files.
 */
export interface TwistSource {
  /**
   * Human-readable display name for the twist
   * @example "Google Calendar Sync"
   */
  displayName: string;

  /**
   * Package dependencies with version specifiers
   * @example { "@plotday/twister": "workspace:^", "@plotday/tool-google-calendar": "^1.0.0" }
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
 * Successful build result containing the bundled module
 */
export interface BuildSuccess {
  success: true;
  module: string;
  /** Optional sourcemap for the bundled module (for stack trace translation) */
  sourcemap?: string;
  /** Whether the container's template cache was hit or missed for this build (e2e/eval observability) */
  templateCache?: "hit" | "miss";
}

/**
 * Failed build result containing error messages
 */
export interface BuildFailure {
  success: false;
  errors: string[];
}

/**
 * Result from building an twist from source
 */
export type BuildResult = BuildSuccess | BuildFailure;
