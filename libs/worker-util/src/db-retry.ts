// SQLSTATE codes for transient transaction failures that Postgres resolves by
// aborting (and fully rolling back) one transaction. Both are safe to retry.
const RETRYABLE_TXN_SQLSTATES = new Set([
  "40P01", // deadlock_detected
  "40001", // serialization_failure
]);

function isRetryableTxnError(error: unknown): boolean {
  if (error && typeof error === "object") {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && RETRYABLE_TXN_SQLSTATES.has(code)) {
      return true;
    }
    // Fallback for drivers/paths that don't surface the SQLSTATE code.
    const msg = (error as { message?: unknown }).message;
    if (typeof msg === "string" && msg.includes("deadlock detected")) {
      return true;
    }
  }
  return false;
}

/** Randomized backoff (ms) to desynchronize the next lock-acquisition attempt
 *  so the two transactions in a deadlock cycle don't immediately re-collide. */
function txnRetryBackoffMs(attempt: number): number {
  return attempt * 20 + Math.floor(Math.random() * 20);
}

/**
 * Run `fn`, retrying on deadlock (40P01) and serialization failure (40001).
 * Only safe when each attempt leaves no committed state behind: a whole
 * explicit transaction, or a single autocommit statement (whose implicit
 * transaction Postgres fully rolls back when it picks it as the victim).
 * Never wrap an individual statement that runs INSIDE an explicit
 * transaction — the surrounding transaction is aborted and must be retried
 * as a unit instead.
 */
export async function retryOnTxnConflict<T>(fn: () => Promise<T>): Promise<T> {
  const maxAttempts = 3;
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt < maxAttempts && isRetryableTxnError(error)) {
        await new Promise((resolve) =>
          setTimeout(resolve, txnRetryBackoffMs(attempt))
        );
        continue;
      }
      throw error;
    }
  }
  throw lastError;
}
