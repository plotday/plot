/**
 * Request ID middleware for API worker.
 *
 * Generates a unique UUID for each request and attaches it to the Hono context.
 * The request ID is also returned in the X-Request-ID response header for client tracking.
 *
 * This enables trace correlation across logs, errors, and distributed operations.
 */

import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";

declare module "hono" {
  interface ContextVariableMap {
    requestId: string;
  }
}

/**
 * Generate a UUID v4 request ID.
 */
function generateRequestId(): string {
  return crypto.randomUUID();
}

/**
 * Request ID middleware.
 *
 * - Generates a unique request ID for each request
 * - Attaches the ID to the Hono context as `c.var.requestId`
 * - Adds X-Request-ID response header
 * - Can accept X-Request-ID from client for request tracing
 *
 * Should be applied early in the middleware chain.
 */
export const requestIdMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  // Check if client provided a request ID (for distributed tracing)
  const clientRequestId = c.req.header("X-Request-ID");

  // Generate new ID or use client-provided ID
  const requestId = clientRequestId || generateRequestId();

  // Attach to context
  c.set("requestId", requestId);

  // Add to response headers
  c.header("X-Request-ID", requestId);

  await next();
};
