import { type AgentEnvironment, type Bindings } from "../env";
import { processStackTrace } from "../utils/stacktrace";

/**
 * Retrieves the sourcemap for an agent from R2 storage.
 *
 * @param env - Bindings containing AGENT_MODULES_BUCKET
 * @param id - Agent ID
 * @param version - Agent version
 * @returns Sourcemap content or undefined if not found
 */
async function getAgentSourcemap(
  env: Bindings,
  id: string,
  version: string
): Promise<string | undefined> {
  try {
    const sourcemapObj = await env.AGENT_MODULES_BUCKET.get(
      `agents/${id}/${version}/sourcemaps`
    );

    if (!sourcemapObj) {
      return undefined;
    }

    return await sourcemapObj.text();
  } catch (error) {
    console.error("Error fetching sourcemap:", error);
    return undefined;
  }
}

/**
 * Helper function to handle agent lifecycle errors with proper logging.
 *
 * This function:
 * 1. Executes the provided operation
 * 2. If an AgentError occurs (from agent worker), extracts the agent stack
 * 3. Processes the stack trace with sourcemaps
 * 4. Logs the error to AGENT_LOGS_QUEUE (user code errors, not API errors)
 * 5. Rethrows the error
 *
 * @param operation - Name of the operation (e.g., "activate", "upgrade")
 * @param fn - Async function to execute
 * @param context - Context including env, agent id, version, environment
 */
export async function handleAgentOperation<T>(
  operation: string,
  fn: () => Promise<T>,
  context: {
    env: Bindings;
    id: string;
    version: string;
    environment: AgentEnvironment;
  }
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    // Extract stack trace - use agentStack if this is an AgentError
    // (captured in agent worker before RPC boundary)
    let stackToProcess: string | undefined;
    let errorName: string;
    let errorMessage: string;

    // Check if this is an encoded AgentError from the agent worker
    if (error instanceof Error && error.message.includes("__AGENT_ERROR__")) {
      try {
        // Extract the JSON data after __AGENT_ERROR__
        const markerIndex = error.message.indexOf("__AGENT_ERROR__");
        const encodedData = error.message.slice(
          markerIndex + "__AGENT_ERROR__".length
        );
        const errorData = JSON.parse(encodedData);
        stackToProcess = errorData.agentStack;
        errorName = errorData.originalError;
        errorMessage = errorData.message;
      } catch (parseError) {
        // Failed to parse encoded error, fall back to treating as regular error
        console.error("Failed to parse encoded AgentError:", parseError);
        stackToProcess = error.stack;
        errorName = error.name;
        errorMessage = error.message;
      }
    } else if (error instanceof Error) {
      // Regular error (shouldn't happen for agent errors, but handle gracefully)
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
      const sourcemap = await getAgentSourcemap(
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

    // Log to agent logs queue ONLY (these are user code errors, not API errors)
    try {
      await context.env.AGENT_LOGS_QUEUE.send({
        agentRootId: context.id,
        environment: context.environment,
        severity: "error",
        message: `Unhandled exception in ${operation}: ${message}`,
        timestamp: Date.now(),
      });
    } catch (logError) {
      // Only log queue failures to API console (infrastructure issue)
      console.error(`Failed to log ${operation} error:`, logError);
    }

    // Rethrow the original error
    throw error;
  }
}
