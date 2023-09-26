import type { PostgrestError } from "@supabase/supabase-js";

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

export function safeQuery<T>({
  data,
  error,
}: {
  data: T;
  error: PostgrestError | null;
}) {
  if (error) {
    throw new DbError(error);
  }
  return data;
}
