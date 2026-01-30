import { type TwistEnvironment, type Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { processStackTrace } from "../utils/stacktrace";

/**
 * Retrieves the sourcemap for a twist from R2 storage.
 *
 * @param env - Bindings containing TWIST_MODULES_BUCKET
 * @param id - Twist ID
 * @param version - Twist version
 * @returns Sourcemap content or undefined if not found
 */
async function getTwistSourcemap(
  env: Bindings,
  id: string,
  version: string
): Promise<string | undefined> {
  try {
    const sourcemapObj = await env.TWIST_MODULES_BUCKET.get(
      `twists/${id}/${version}/sourcemaps`
    );

    if (!sourcemapObj) {
      return undefined;
    }

    return await sourcemapObj.text();
  } catch (error) {
    const logger = createLogger();
    logger.error("Error fetching sourcemap", error as Error, { twist_id: id, version });
    return undefined;
  }
}

/**
 * Helper function to handle twist lifecycle errors with proper logging.
 *
 * This function:
 * 1. Executes the provided operation
 * 2. If a TwistError occurs (from twist worker), extracts the twist stack
 * 3. Processes the stack trace with sourcemaps
 * 4. Logs the error to TWIST_LOGS_QUEUE (user code errors, not API errors)
 * 5. Rethrows the error
 *
 * @param operation - Name of the operation (e.g., "activate", "upgrade")
 * @param fn - Async function to execute
 * @param context - Context including env, twist id, version, environment
 */
export async function handleTwistOperation<T>(
  operation: string,
  fn: () => Promise<T>,
  context: {
    env: Bindings;
    id: string;
    version: string;
    environment: TwistEnvironment;
  }
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    // Extract stack trace - use twistStack if this is a TwistError
    // (captured in twist worker before RPC boundary)
    let stackToProcess: string | undefined;
    let errorName: string;
    let errorMessage: string;

    // Check if this is an encoded TwistError from the twist worker
    if (error instanceof Error && error.message.includes("__TWIST_ERROR__")) {
      try {
        // Extract the JSON data after __TWIST_ERROR__
        const markerIndex = error.message.indexOf("__TWIST_ERROR__");
        const encodedData = error.message.slice(
          markerIndex + "__TWIST_ERROR__".length
        );
        const errorData = JSON.parse(encodedData);
        stackToProcess = errorData.twistStack;
        errorName = errorData.originalError;
        errorMessage = errorData.message;
      } catch (parseError) {
        // Failed to parse encoded error, fall back to treating as regular error
        const logger = createLogger({ twist_id: context.id, environment: context.environment });
        logger.error("Failed to parse encoded TwistError", parseError as Error);
        stackToProcess = error.stack;
        errorName = error.name;
        errorMessage = error.message;
      }
    } else if (error instanceof Error) {
      // Regular error (shouldn't happen for twist errors, but handle gracefully)
      stackToProcess = error.stack;
      errorName = error.name;
      errorMessage = error.message;
    } else {
      // Non-Error thrown
      errorName = "Unknown";
      errorMessage = String(error);
    }

    // Process stack trace with sourcemap if available
    let message: string;
    if (stackToProcess) {
      const sourcemap = await getTwistSourcemap(
        context.env,
        context.id,
        context.version
      );

      // Create a temporary error object for stack processing
      const tempError = new Error(errorMessage);
      tempError.stack = stackToProcess;
      tempError.name = errorName;

      const processedStack = await processStackTrace(tempError, sourcemap);
      message = `\n${errorName}: ${errorMessage}${
        processedStack ? `\n${processedStack}` : ""
      }`;
    } else {
      message = `\n${errorName}: ${errorMessage}`;
    }

    // Log to twist logs queue ONLY (these are user code errors, not API errors)
    try {
      await context.env.TWIST_LOGS_QUEUE.send({
        twistRootId: context.id,
        environment: context.environment,
        severity: "error",
        message: `Unhandled exception in ${operation}: ${message}`,
        timestamp: Date.now(),
      });
    } catch (logError) {
      // Only log queue failures to API console (infrastructure issue)
      const logger = createLogger({ twist_id: context.id, environment: context.environment, operation });
      logger.error("Failed to log twist operation error", logError as Error);
    }

    // Rethrow the original error
    throw error;
  }
}
