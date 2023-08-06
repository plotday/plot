import type { PostgrestError } from "@supabase/supabase-js";

export function safeQuery<T>({
  data,
  error,
}: {
  data: T;
  error: PostgrestError | null;
}) {
  if (error) {
    const exception = new Error(error.message || "Database error", {
      cause: error,
    });
    throw exception;
  }
  return data;
}
