/**
 * Network error handling utility for Twister CLI
 * Converts technical fetch/network errors into user-friendly messages
 */

export interface NetworkErrorResult {
  message: string;
  details?: string;
  shouldRetry: boolean;
}

/**
 * Checks if an error is a network-related error
 */
function isNetworkError(error: unknown): boolean {
  if (error && typeof error === "object") {
    const err = error as any;
    // Check for common network error codes
    if (err.code) {
      return [
        "ECONNREFUSED",
        "ENOTFOUND",
        "ETIMEDOUT",
        "ECONNRESET",
        "ENETUNREACH",
        "EAI_AGAIN",
      ].includes(err.code);
    }
    // Check for fetch failed errors
    if (err.cause && typeof err.cause === "object") {
      const cause = err.cause as any;
      return cause.code && typeof cause.code === "string";
    }
  }
  return false;
}

/**
 * Extracts the error code from a network error
 */
function getErrorCode(error: unknown): string | undefined {
  if (error && typeof error === "object") {
    const err = error as any;
    if (err.code) return err.code;
    if (err.cause && typeof err.cause === "object") {
      return (err.cause as any).code;
    }
  }
  return undefined;
}

/**
 * Handles network errors and returns user-friendly error information
 */
export function handleNetworkError(
  error: unknown,
  context?: string
): NetworkErrorResult {
  // Handle HTTP Response errors (non-2xx responses)
  if (error && typeof error === "object" && "status" in error) {
    const status = (error as any).status;
    if (typeof status === "number") {
      switch (true) {
        case status === 401 || status === 403:
          return {
            message: "Authentication failed. Please log in again.",
            shouldRetry: false,
          };
        case status === 404:
          return {
            message: "API endpoint not found. You may need to update your CLI.",
            shouldRetry: false,
          };
        case status === 429:
          return {
            message: "Too many requests. Please wait a moment and try again.",
            shouldRetry: true,
          };
        case status >= 500:
          return {
            message: "Plot API is experiencing issues. Please try again later.",
            shouldRetry: true,
          };
        default:
          return {
            message: `Request failed with status ${status}. Please try again later.`,
            shouldRetry: true,
          };
      }
    }
  }

  // Handle network connectivity errors
  if (isNetworkError(error)) {
    const code = getErrorCode(error);
    switch (code) {
      case "ECONNREFUSED":
        return {
          message:
            "Could not connect to Plot API. Please check your internet connection or try again later.",
          details: context,
          shouldRetry: true,
        };
      case "ENOTFOUND":
        return {
          message:
            "Could not reach Plot API. Please check your internet connection.",
          details: context,
          shouldRetry: true,
        };
      case "ETIMEDOUT":
      case "ECONNRESET":
        return {
          message: "Connection to Plot API timed out. Please try again later.",
          details: context,
          shouldRetry: true,
        };
      case "ENETUNREACH":
      case "EAI_AGAIN":
        return {
          message:
            "Network unreachable. Please check your internet connection.",
          details: context,
          shouldRetry: true,
        };
      default:
        return {
          message:
            "Network error occurred. Please check your internet connection or try again later.",
          details: context,
          shouldRetry: true,
        };
    }
  }

  // Handle timeout errors from AbortController
  if (error instanceof Error && error.name === "AbortError") {
    return {
      message: "Request timed out. Please try again later.",
      details: context,
      shouldRetry: true,
    };
  }

  // Handle generic errors
  const errorMessage = error instanceof Error ? error.message : String(error);
  return {
    message: "An unexpected error occurred. Please try again later.",
    details: errorMessage,
    shouldRetry: true,
  };
}

/**
 * Formats a network error for display to the user
 */
export function formatNetworkError(error: unknown, context?: string): string {
  const result = handleNetworkError(error, context);
  if (result.details) {
    return `${result.message}\n${result.details}`;
  }
  return result.message;
}
