/**
 * Structured logging utility for the API worker.
 *
 * Provides automatic context injection, request ID tracking, and environment-aware
 * output formatting (JSON in production, human-readable in development).
 *
 * All logs are exported to PostHog via OpenTelemetry with automatic trace correlation.
 */

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
 * Log entry structure for JSON output.
 */
interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  error?: {
    message: string;
    stack?: string;
    name?: string;
  };
  context: LogContext;
}

/**
 * Structured logger with automatic context injection and environment-aware formatting.
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
   * Internal log method that formats and outputs the log entry.
   */
  private log(level: LogLevel, message: string, error?: Error, context?: LogContext): void {
    const mergedContext = { ...this.baseContext, ...context };
    const timestamp = new Date().toISOString();

    const entry: LogEntry = {
      timestamp,
      level,
      message,
      context: mergedContext,
    };

    // Add error details if present
    if (error) {
      entry.error = {
        name: error.name,
        message: error.message,
        stack: error.stack,
      };
    }

    // Output based on environment
    if (this.env === "production") {
      this.outputJson(entry);
    } else {
      this.outputHumanReadable(entry);
    }
  }

  /**
   * Output log entry as JSON (production).
   */
  private outputJson(entry: LogEntry): void {
    const output = JSON.stringify(entry);

    switch (entry.level) {
      case LogLevel.DEBUG:
      case LogLevel.INFO:
        console.log(output);
        break;
      case LogLevel.WARN:
        console.warn(output);
        break;
      case LogLevel.ERROR:
      case LogLevel.FATAL:
        console.error(output);
        break;
    }
  }

  /**
   * Output log entry in human-readable format (development).
   */
  private outputHumanReadable(entry: LogEntry): void {
    const levelColor = this.getLevelColor(entry.level);
    const levelStr = entry.level.toUpperCase().padEnd(5);
    const requestId = entry.context.request_id
      ? ` [req:${entry.context.request_id.substring(0, 8)}]`
      : '';

    // Main log line
    const mainLine = `[${entry.timestamp}] ${levelColor}${levelStr}\x1b[0m${requestId} ${entry.message}`;

    // Context lines (exclude request_id since it's in the header)
    const contextLines: string[] = [];
    for (const [key, value] of Object.entries(entry.context)) {
      if (key === 'request_id') continue; // Already shown in header
      if (value !== undefined && value !== null) {
        contextLines.push(`  ${key}: ${this.formatValue(value)}`);
      }
    }

    // Error details
    if (entry.error) {
      contextLines.push(`  error: ${entry.error.message}`);
      if (entry.error.stack) {
        // Indent stack trace
        const stackLines = entry.error.stack.split('\n').slice(1); // Skip first line (message)
        contextLines.push(...stackLines.map(line => `    ${line.trim()}`));
      }
    }

    // Output
    const fullMessage = contextLines.length > 0
      ? `${mainLine}\n${contextLines.join('\n')}`
      : mainLine;

    switch (entry.level) {
      case LogLevel.DEBUG:
      case LogLevel.INFO:
        console.log(fullMessage);
        break;
      case LogLevel.WARN:
        console.warn(fullMessage);
        break;
      case LogLevel.ERROR:
      case LogLevel.FATAL:
        console.error(fullMessage);
        break;
    }
  }

  /**
   * Get ANSI color code for log level.
   */
  private getLevelColor(level: LogLevel): string {
    switch (level) {
      case LogLevel.DEBUG:
        return '\x1b[36m'; // Cyan
      case LogLevel.INFO:
        return '\x1b[32m'; // Green
      case LogLevel.WARN:
        return '\x1b[33m'; // Yellow
      case LogLevel.ERROR:
        return '\x1b[31m'; // Red
      case LogLevel.FATAL:
        return '\x1b[35m'; // Magenta
    }
  }

  /**
   * Format value for human-readable output.
   */
  private formatValue(value: unknown): string {
    if (typeof value === 'string') return value;
    if (typeof value === 'number') return String(value);
    if (typeof value === 'boolean') return String(value);
    if (value === null) return 'null';
    if (value === undefined) return 'undefined';
    if (value instanceof Date) return value.toISOString();
    if (Array.isArray(value)) return `[${value.length} items]`;
    if (typeof value === 'object') return JSON.stringify(value);
    return String(value);
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
