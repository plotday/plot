/**
 * Utilities for extracting log context from various sources.
 *
 * Provides consistent context extraction from Hono requests, queue messages,
 * and error objects for use with the structured logger.
 */

import type { Context } from "hono";
import type { LogContext } from "@plotday/worker-util";
import type { Bindings, LogMessage } from "../env";
import type { RunMessage } from "../twist/tools/tasks";
import { DbError } from "@plotday/db";

/**
 * Extract log context from Hono request context.
 *
 * Extracts request_id, user_id, path, method, and url from the Hono context.
 */
export function extractRequestContext(c: Context<{ Bindings: Bindings }>): LogContext {
  const context: LogContext = {
    request_id: c.var.requestId,
    path: c.req.path,
    method: c.req.method,
    url: c.req.url,
  };

  // Add user_id if authenticated
  try {
    const user = c.var.user;
    if (user?.id) {
      context.user_id = user.id;
    }
  } catch {
    // User not available (not authenticated or middleware not run)
  }

  return context;
}

/**
 * Extract log context from run queue messages (callback execution).
 *
 * Extracts priority_twist_id, path, callback token.
 */
export function extractRunQueueContext(
  message: RunMessage,
  queue?: string
): LogContext {
  return {
    queue: queue ?? "run",
    priority_twist_id: message.priorityTwistId,
    path: message.path.join("/"),
    callback_token: message.token,
  };
}

/**
 * Extract log context from log queue messages.
 *
 * Extracts twist_root_id, environment, severity.
 */
export function extractLogQueueContext(
  message: LogMessage,
  queue?: string
): LogContext {
  return {
    queue: queue ?? "twist-logs",
    twist_root_id: message.twistRootId,
    environment: message.environment,
    severity: message.severity,
  };
}

/**
 * Extract log context from Error objects.
 *
 * Categorizes errors by type based on name, message, and properties.
 */
export function extractErrorContext(error: Error | unknown): LogContext {
  if (!(error instanceof Error)) {
    return {
      error_type: "unknown",
    };
  }

  const context: LogContext = {
    error_type: categorizeError(error),
    error_name: error.name,
    error_message: error.message,
  };

  // Handle DbError specially to extract rich debugging context
  if (error instanceof DbError) {
    context.error_type = "database";
    Object.assign(context, error.toLogContext());
  }

  // Extract any custom properties from the error
  // (e.g., TwistError might have additional context)
  const errorObj = error as any;
  if (errorObj.twist_id) context.twist_id = errorObj.twist_id;
  if (errorObj.priority_twist_id) context.priority_twist_id = errorObj.priority_twist_id;
  if (errorObj.priority_id) context.priority_id = errorObj.priority_id;
  if (errorObj.operation) context.operation = errorObj.operation;

  return context;
}

/**
 * Categorize error by type based on name and message.
 */
function categorizeError(error: Error): string {
  const message = error.message.toLowerCase();
  const name = error.name.toLowerCase();

  // Validation errors
  if (name.includes("validation") || message.includes("validation")) {
    return "validation";
  }

  // Authentication/authorization errors
  if (
    name.includes("auth") ||
    message.includes("unauthorized") ||
    message.includes("forbidden") ||
    message.includes("authentication") ||
    message.includes("permission")
  ) {
    return "authentication";
  }

  // Database errors
  if (
    name.includes("database") ||
    name.includes("supabase") ||
    message.includes("database") ||
    message.includes("query") ||
    message.includes("duplicate key")
  ) {
    return "database";
  }

  // Network errors
  if (
    name.includes("network") ||
    name.includes("timeout") ||
    message.includes("network") ||
    message.includes("timeout") ||
    message.includes("econnrefused") ||
    message.includes("fetch failed")
  ) {
    return "network";
  }

  // Twist runtime errors
  if (
    name.includes("twist") ||
    message.includes("twist") ||
    message.includes("callback")
  ) {
    return "twist_runtime";
  }

  // OAuth/Integration errors
  if (
    message.includes("oauth") ||
    message.includes("token") ||
    message.includes("refresh")
  ) {
    return "oauth";
  }

  // Generic errors
  if (name === "error") {
    return "application";
  }

  // Unknown category
  return name || "unknown";
}

/**
 * Merge multiple log contexts, with later contexts taking precedence.
 */
export function mergeContext(...contexts: (LogContext | undefined)[]): LogContext {
  const merged: LogContext = {};

  for (const context of contexts) {
    if (context) {
      Object.assign(merged, context);
    }
  }

  return merged;
}

/**
 * Add twist-specific context for twist operations.
 */
export function addTwistContext(
  twistId?: string | number,
  priorityTwistId?: string,
  priorityId?: string | number,
  environment?: "personal" | "private" | "review" | "public"
): LogContext {
  const context: LogContext = {};

  if (twistId) context.twist_id = String(twistId);
  if (priorityTwistId) context.priority_twist_id = priorityTwistId;
  if (priorityId) context.priority_id = String(priorityId);
  if (environment) context.environment = environment;

  return context;
}

/**
 * Add operation context for tracking specific operations.
 */
export function addOperationContext(
  operation: string,
  durationMs?: number,
  additionalContext?: Record<string, unknown>
): LogContext {
  const context: LogContext = {
    operation,
  };

  if (durationMs !== undefined) {
    context.duration_ms = durationMs;
  }

  if (additionalContext) {
    Object.assign(context, additionalContext);
  }

  return context;
}
