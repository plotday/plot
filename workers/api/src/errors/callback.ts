export type CallbackErrorType =
  | "INVALID_TOKEN_FORMAT" // Malformed token (not 64 hex chars)
  | "INVALID_TOKEN" // Empty or missing token
  | "NOT_FOUND" // Callback doesn't exist in storage
  | "EXPIRED" // Callback has passed expiration date
  | "UNINITIALIZED"; // Webhook functionality not set up

export interface CallbackErrorContext {
  operation?: string; // e.g., "callCallback", "create"
  token?: string; // Sanitized token (no sensitive data)
  priorityTwistId?: string;
  reason?: string; // Additional context
}

export class CallbackError extends Error {
  readonly type: CallbackErrorType;
  readonly context?: CallbackErrorContext;

  constructor(type: CallbackErrorType, context?: CallbackErrorContext) {
    const messageMap: Record<CallbackErrorType, string> = {
      INVALID_TOKEN_FORMAT: "Invalid callback token format",
      INVALID_TOKEN: "Invalid callback token",
      NOT_FOUND: "Callback not found",
      EXPIRED: "Callback has expired",
      UNINITIALIZED: "Webhook functionality not initialized",
    };

    super(messageMap[type]);
    this.name = "CallbackError";
    this.type = type;
    this.context = context;

    // Maintain proper stack trace for V8
    // @ts-ignore - V8-specific feature not in all TypeScript lib versions
    if (Error.captureStackTrace) {
      // @ts-ignore
      Error.captureStackTrace(this, CallbackError);
    }
  }

  toLogContext(): Record<string, unknown> {
    return {
      errorType: this.type,
      errorName: this.name,
      message: this.message,
      ...this.context,
    };
  }
}

export function isCallbackError(error: unknown): error is CallbackError {
  if (error instanceof CallbackError) {
    return true;
  }

  // When errors cross DO boundaries, they get wrapped in generic Error objects
  // with the original class name prepended to the message: "CallbackError: ..."
  if (
    error instanceof Error &&
    typeof error.message === "string" &&
    error.message.startsWith("CallbackError: ")
  ) {
    return true;
  }

  return false;
}

/**
 * Extract the error type from a CallbackError, handling DO serialization.
 * Returns the error type string or undefined if not available.
 */
export function getCallbackErrorType(
  error: CallbackError | Error
): CallbackErrorType | undefined {
  // Direct access if it's an actual CallbackError instance
  if ("type" in error && typeof (error as any).type === "string") {
    return (error as any).type as CallbackErrorType;
  }

  // Parse from message for DO-serialized errors
  // Message format: "CallbackError: <message>"
  // We need to map the message back to the error type
  if (error.message.startsWith("CallbackError: ")) {
    const message = error.message.substring("CallbackError: ".length);
    const messageToType: Record<string, CallbackErrorType> = {
      "Invalid callback token format": "INVALID_TOKEN_FORMAT",
      "Invalid callback token": "INVALID_TOKEN",
      "Callback not found": "NOT_FOUND",
      "Callback has expired": "EXPIRED",
      "Webhook functionality not initialized": "UNINITIALIZED",
    };
    return messageToType[message];
  }

  return undefined;
}
