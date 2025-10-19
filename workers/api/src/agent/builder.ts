import { getContainer } from "@cloudflare/containers";

import type { Bindings } from "../env";
import type { AgentSource, BuildResult } from "./types";

/**
 * Builds an agent from source code in an isolated container environment.
 *
 * This function:
 * 1. Gets a container instance running the agent builder server
 * 2. Sends the source code to the /build endpoint via HTTP POST
 * 3. Returns the bundled module or build errors from the server
 *
 * The container runs a Node.js server that:
 * - Creates a unique temporary directory for each build
 * - Sets up the agent project structure using the Plot CLI
 * - Writes source files and dependencies
 * - Runs npm install and plot agent build
 * - Cleans up the temporary directory after the build
 *
 * @param source - Agent source code containing dependencies and files
 * @param env - Bindings containing Sandbox (Container) configuration
 * @returns Promise resolving to build result (success with module or failure with errors)
 */
export async function buildAgent(
  source: AgentSource,
  env: Bindings
): Promise<BuildResult> {
  // Validate that index.ts exists
  if (!source.files["index.ts"]) {
    return {
      success: false,
      errors: ["Required file 'index.ts' is missing from source.files"],
    };
  }

  // Validate Sandbox (Container) binding
  if (!env.AGENT_BUILDER) {
    return {
      success: false,
      errors: ["Sandbox (Container) binding is not configured"],
    };
  }

  try {
    // Get a container instance
    // We use a consistent ID "builder" to reuse the same container instance
    // for better performance (warm starts)
    const container = getContainer(env.AGENT_BUILDER, "builder");

    // Send build request to the container's HTTP server
    const response = await container.fetch("http://localhost:3000/build", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(source),
    });

    // Check if the HTTP request was successful
    if (!response.ok) {
      const errorText = await response.text();
      return {
        success: false,
        errors: [
          `Container build request failed with status ${response.status}:\n${errorText}`,
        ],
      };
    }

    // Parse the build result from the response
    const result: BuildResult = await response.json();
    return result;
  } catch (error) {
    return {
      success: false,
      errors: [
        `Build failed with exception: ${
          error instanceof Error ? error.message : JSON.stringify(error)
        }`,
      ],
    };
  }
}
