/**
 * Custom error type for agent errors that cross the RPC boundary.
 *
 * This error type preserves the original stack trace from the agent worker,
 * allowing us to process it with sourcemaps in the API worker.
 */
export interface AgentError extends Error {
  name: "AgentError";
  /** Original stack trace captured in the agent worker before RPC boundary */
  agentStack: string;
  /** Operation that failed (e.g., "activate", "callCallback(onAuth)") */
  operation: string;
  /** Original error name (e.g., "TypeError", "Error") */
  originalError: string;
}

/**
 * Type guard to check if an error is an AgentError
 */
export function isAgentError(error: unknown): error is AgentError {
  return (
    error instanceof Error &&
    error.name === "AgentError" &&
    "agentStack" in error &&
    "operation" in error &&
    "originalError" in error
  );
}
