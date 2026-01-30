/**
 * Structured logging utility for Cloudflare Workers.
 *
 * Provides automatic context injection, request ID tracking, and uses native
 * console methods with message + context format for better log formatting.
 *
 * All logs are exported to PostHog via OpenTelemetry with automatic trace correlation.
 */

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

export enum LogLevel {
  DEBUG = "debug",
  INFO = "info",
  WARN = "warn",
  ERROR = "error",
  FATAL = "fatal",
}

/**
 * Standard log context fields that can be automatically injected.
 */
export interface LogContext {
  // Request tracking
  request_id?: string;

  // User context
  user_id?: string;

  // Priority/Twist context
  priority_id?: string;
  priority_twist_id?: string;
  twist_id?: string;
  twist_root_id?: string;

  // Environment
  environment?: "personal" | "private" | "review" | "public" | "development" | "production";

  // Request context
  path?: string;
  method?: string;
  url?: string;

  // Queue context
  queue?: string;
  batch_size?: number;

  // Operation context
  operation?: string;
  error_type?: string;

  // Performance
  duration_ms?: number;

  // Custom fields
  [key: string]: unknown;
}

/**
 * Structured logger with automatic context injection.
 *
 * Uses native console methods (console.log, console.warn, console.error) with
 * message + context format for better automatic formatting by Cloudflare Workers.
 */
export class Logger {
  private baseContext: LogContext;
  private env: "development" | "production";

  constructor(baseContext: LogContext = {}, env: "development" | "production" = "production") {
    this.baseContext = baseContext;
    this.env = env;
  }

  /**
   * Create a child logger with additional base context.
   */
  child(additionalContext: LogContext): Logger {
    return new Logger(
      { ...this.baseContext, ...additionalContext },
      this.env
    );
  }

  /**
   * Log a debug message (verbose, development only).
   */
  debug(message: string, context?: LogContext): void {
    if (this.env === "production") return; // Skip debug logs in production
    this.log(LogLevel.DEBUG, message, undefined, context);
  }

  /**
   * Log an informational message.
   */
  info(message: string, context?: LogContext): void {
    this.log(LogLevel.INFO, message, undefined, context);
  }

  /**
   * Log a warning message.
   */
  warn(message: string, context?: LogContext): void;
  warn(message: string, error?: Error, context?: LogContext): void;
  warn(message: string, errorOrContext?: Error | LogContext, context?: LogContext): void {
    const { error, ctx } = this.parseErrorAndContext(errorOrContext, context);
    this.log(LogLevel.WARN, message, error, ctx);
  }

  /**
   * Log an error message.
   */
  error(message: string, context?: LogContext): void;
  error(message: string, error?: Error, context?: LogContext): void;
  error(message: string, errorOrContext?: Error | LogContext, context?: LogContext): void {
    const { error, ctx } = this.parseErrorAndContext(errorOrContext, context);
    this.log(LogLevel.ERROR, message, error, ctx);
  }

  /**
   * Log a fatal error (critical failure).
   */
  fatal(message: string, context?: LogContext): void;
  fatal(message: string, error?: Error, context?: LogContext): void;
  fatal(message: string, errorOrContext?: Error | LogContext, context?: LogContext): void {
    const { error, ctx } = this.parseErrorAndContext(errorOrContext, context);
    this.log(LogLevel.FATAL, message, error, ctx);
  }

  /**
   * Internal log method that uses native console methods with message + context.
   *
   * Cloudflare Workers automatically adds timestamps and formats log levels,
   * so we rely on native console methods instead of custom formatting.
   */
  private log(level: LogLevel, message: string, error?: Error, context?: LogContext): void {
    const mergedContext = { ...this.baseContext, ...context };

    // Filter out undefined/null values to keep logs clean
    const filteredContext: LogContext = {};
    for (const [key, value] of Object.entries(mergedContext)) {
      if (value !== undefined && value !== null) {
        filteredContext[key] = value;
      }
    }

    const hasContext = Object.keys(filteredContext).length > 0;

    // Use native console methods with message + context/error format
    switch (level) {
      case LogLevel.DEBUG:
      case LogLevel.INFO:
        if (hasContext) {
          console.log(message, filteredContext);
        } else {
          console.log(message);
        }
        break;
      case LogLevel.WARN:
        if (error) {
          if (hasContext) {
            console.warn(message, error, filteredContext);
          } else {
            console.warn(message, error);
          }
        } else {
          if (hasContext) {
            console.warn(message, filteredContext);
          } else {
            console.warn(message);
          }
        }
        break;
      case LogLevel.ERROR:
      case LogLevel.FATAL:
        if (error) {
          if (hasContext) {
            console.error(message, error, filteredContext);
          } else {
            console.error(message, error);
          }
        } else {
          if (hasContext) {
            console.error(message, filteredContext);
          } else {
            console.error(message);
          }
        }
        break;
    }
  }

  /**
   * Parse error and context from method arguments (handles overloads).
   */
  private parseErrorAndContext(
    errorOrContext?: Error | LogContext,
    context?: LogContext
  ): { error?: Error; ctx?: LogContext } {
    if (!errorOrContext) {
      return { error: undefined, ctx: context };
    }

    if (errorOrContext instanceof Error) {
      return { error: errorOrContext, ctx: context };
    }

    return { error: undefined, ctx: errorOrContext };
  }
}

/**
 * Create a logger instance with optional base context and environment.
 */
export function createLogger(
  baseContext: LogContext = {},
  env?: "development" | "production"
): Logger {
  // Auto-detect environment from global ENV constant if not provided
  const environment = env ?? (typeof ENV !== 'undefined' ? ENV as "development" | "production" : "production");
  return new Logger(baseContext, environment);
}

/**
 * Default logger instance (no base context).
 * Use this for quick logging or create a child logger with context.
 */
export const logger = createLogger();
