import type {
  PostgrestError,
  PostgrestSingleResponse,
} from "@supabase/supabase-js";

export interface DbErrorContext {
  table?: string;
  operation?: string;
  description?: string;
  identifiers?: Record<string, unknown>;
}

export class DbError extends Error {
  readonly table?: string;
  readonly operation?: string;
  readonly description?: string;
  readonly identifiers?: Record<string, unknown>;
  readonly code?: string;
  readonly hint?: string;
  readonly details?: string;

  constructor(cause: PostgrestError, context?: DbErrorContext) {
    const message = cause.message ?? "Database error";
    // Pass remaining arguments (including vendor specific ones) to parent constructor
    super(message, { cause });

    this.name = "DbError";

    // Extract PostgrestError details
    this.code = cause.code;
    this.hint = cause.hint;
    this.details = cause.details;

    // Store context for debugging
    this.table = context?.table;
    this.operation = context?.operation;
    this.description = context?.description;
    this.identifiers = context?.identifiers;

    // Maintains proper stack trace for where our error was thrown (only available on V8)
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, DbError);
    }
  }

  toLogContext(): Record<string, unknown> {
    const context: Record<string, unknown> = {};

    if (this.code) context.db_code = this.code;
    if (this.hint) context.db_hint = this.hint;
    if (this.details) context.db_details = this.details;
    if (this.table) context.db_table = this.table;
    if (this.operation) context.db_operation = this.operation;
    if (this.description) context.db_description = this.description;

    // Spread identifiers at the top level for easy querying in PostHog
    if (this.identifiers) {
      Object.assign(context, this.identifiers);
    }

    return context;
  }
}

export function safeQuery<T>(
  response: PostgrestSingleResponse<T>,
  context?: DbErrorContext
): T;
export function safeQuery<T>(
  response: PromiseLike<PostgrestSingleResponse<T>>,
  context?: DbErrorContext
): PromiseLike<T>;

export function safeQuery<T>(
  response: PostgrestSingleResponse<T> | PromiseLike<PostgrestSingleResponse<T>>,
  context?: DbErrorContext
): T | PromiseLike<T> {
  if ("then" in response) {
    return response.then((r) => safeQuery<T>(r, context));
  } else {
    if (response.error) {
      throw new DbError(response.error, context);
    }
    return response.data;
  }
}
