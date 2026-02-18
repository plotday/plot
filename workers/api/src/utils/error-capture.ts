/**
 * Centralized error capture utility for API route handlers.
 *
 * Ensures that all server errors are:
 * 1. Logged to console with structured context
 * 2. Captured in PostHog for monitoring
 * 3. Returned as consistent 500 responses
 */

import type { Context } from "hono";
import type { Bindings } from "../env";
import { extractRequestContext, extractErrorContext, mergeContext } from "./log-context";
import { createLogger } from "@plotday/worker-util";

/**
 * Capture a server error, log it to console and PostHog, and return a 500 response.
 *
 * Use this in route handlers instead of manually logging and returning errors.
 * This ensures consistent error handling and that all errors are tracked in PostHog.
 *
 * @param c - Hono context
 * @param error - The error that occurred (Error object or unknown)
 * @param message - User-facing error message for the response
 * @param additionalContext - Optional additional context to include in logs
 * @returns Response with 500 status and error message
 *
 * @example
 * ```typescript
 * if (dbError) {
 *   return captureServerError(c, new Error(dbError.message), "Failed to save data", {
 *     user_id: user.id,
 *     operation: "save_user",
 *   });
 * }
 * ```
 */
export function captureServerError(
  c: Context<{ Bindings: Bindings }>,
  error: Error | unknown,
  message: string,
  additionalContext?: Record<string, unknown>
): Response {
  const err = error instanceof Error ? error : new Error(String(error));

  try {
    // Extract context from request and error
    const requestContext = extractRequestContext(c);
    const errorContext = extractErrorContext(err);
    const context = mergeContext(requestContext, errorContext, additionalContext);

    // Log error with structured context
    const logger = createLogger();
    logger.error(message, err, context);

    // Capture in PostHog with same context
    c.var.tracker.captureException(err, {
      ...context,
      path: c.req.path,
      method: c.req.method,
      url: c.req.url,
    });
  } catch (e) {
    // Fallback to console if structured logging fails
    console.error("Error in captureServerError:", e);
    console.error("Original error:", err);
  }

  return c.json({ message }, 500);
}
