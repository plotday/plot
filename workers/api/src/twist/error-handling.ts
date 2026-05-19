import { PostHog } from "posthog-node";

import { type TwistEnvironment, type Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { processStackTrace } from "../utils/stacktrace";
import { Tracker } from "../utils/tracker";
import { isTransientError } from "../utils/transient-error";
import { ThreadFilingSkippedError } from "./tools/plot/thread-helpers";

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
    /**
     * Used for `waitUntil(tracker.shutdown(...))` so the PostHog escalation
     * for unhandled twist exceptions can flush after the response is sent.
     * Optional — when absent, the escalation step is skipped (logging to
     * TWIST_LOGS_QUEUE still happens). Pass through from the caller's
     * request-scoped or scheduled-handler ExecutionContext.
     */
    ctx?: { waitUntil: ExecutionContext["waitUntil"] };
  }
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    // Cloudflare-side infrastructure blips (cross-worker RPC drops,
    // Hyperdrive resets, transient Queue producer 5xxs) surface here as
    // ordinary Errors but are not actionable by twist developers. Queue
    // consumers (`Tasks.processQueue`, `processWebhooks`) already retry
    // these silently — escalating them to TWIST_LOGS_QUEUE or PostHog
    // would just add noise to the user-facing twist log on every retry.
    if (isTransientError(error)) {
      throw error;
    }

    // ThreadFilingSkippedError is a "skip" sentinel, not a failure. It fires
    // when a team-connector tries to file a thread for a user who has no
    // priority in the team — a normal outcome of stale team membership.
    // Suppress it from the twist log and PostHog Error Tracking so it doesn't
    // pollute error reporting. Still rethrow so callers can short-circuit.
    if (error instanceof ThreadFilingSkippedError) {
      throw error;
    }

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

    // Log to twist logs queue (user-facing twist log UI). Connector code runs
    // in a separately-loaded Worker (see workers/api/src/twist/loader.ts) with
    // no PostHog observability binding, so this queue is the only sink the
    // connector's own console.* writes reach.
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

    // Surface the unhandled twist exception to PostHog Error Tracking so
    // recurring connector failures group into a single issue alongside api
    // worker errors. Without this, twist throws live only in the per-twist
    // log queue and aren't visible in our shared error-tracking view.
    if (context.ctx && context.env.POSTHOG_API_KEY) {
      try {
        const surfacedError = new Error(`${errorName}: ${errorMessage}`);
        surfacedError.name = errorName;
        if (stackToProcess) surfacedError.stack = stackToProcess;
        const postHog = new PostHog(context.env.POSTHOG_API_KEY, {
          host: context.env.POSTHOG_HOST,
          flushAt: 1,
          flushInterval: 0,
        });
        const tracker = new Tracker(postHog);
        tracker.captureException(surfacedError, {
          twist_id: context.id,
          twist_version: context.version,
          environment: context.environment,
          operation,
          source: "handleTwistOperation",
        });
        context.ctx.waitUntil(tracker.shutdown(2000));
      } catch (escalationError) {
        const logger = createLogger({ twist_id: context.id, environment: context.environment, operation });
        logger.error("Failed to escalate twist error to PostHog", escalationError as Error);
      }
    }

    // Rethrow the original error
    throw error;
  }
}
