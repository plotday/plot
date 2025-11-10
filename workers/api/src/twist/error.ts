/**
 * Custom error type for twist errors that cross the RPC boundary.
 *
 * This error type preserves the original stack trace from the twist worker,
 * allowing us to process it with sourcemaps in the API worker.
 */
export interface TwistError extends Error {
  name: "TwistError";
  /** Original stack trace captured in the twist worker before RPC boundary */
  twistStack: string;
  /** Operation that failed (e.g., "activate", "callCallback(onAuth)") */
  operation: string;
  /** Original error name (e.g., "TypeError", "Error") */
  originalError: string;
}

/**
 * Type guard to check if an error is an TwistError
 */
export function isTwistError(error: unknown): error is TwistError {
  return (
    error instanceof Error &&
    error.name === "TwistError" &&
    "twistStack" in error &&
    "operation" in error &&
    "originalError" in error
  );
}
