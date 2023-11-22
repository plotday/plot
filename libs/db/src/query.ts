import type {
  PostgrestError,
  PostgrestSingleResponse,
} from "@supabase/supabase-js";

export class DbError extends Error {
  constructor(cause: PostgrestError) {
    const message = cause.message ?? "Database error";
    // Pass remaining arguments (including vendor specific ones) to parent constructor
    super(message, { cause });

    this.name = "DbError";

    // Maintains proper stack trace for where our error was thrown (only available on V8)
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, DbError);
    }
  }
}

export function safeQuery<T>(response: PostgrestSingleResponse<T>): T;
export function safeQuery<T>(
  response: PromiseLike<PostgrestSingleResponse<T>>
): PromiseLike<T>;

export function safeQuery<T>(
  response: PostgrestSingleResponse<T> | PromiseLike<PostgrestSingleResponse<T>>
): T | PromiseLike<T> {
  if ("then" in response) {
    return response.then(safeQuery<T>);
  } else {
    if (response.error) {
      throw new DbError(response.error);
    }
    return response.data;
  }
}
