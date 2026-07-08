import type { Bindings } from "../env";
import type { TwistSource, BuildResult } from "./types";
// The twister exports map has no ./package.json entry, so import it by
// path. This is the SAME package the prompt docs come from — sending its
// version pins container builds to the docs the model saw.
import twisterPackage from "../../node_modules/@plotday/twister/package.json";

/**
 * Resolve `getContainer` from `@cloudflare/containers` lazily via a dynamic
 * import. A dynamic import turns a module-load failure into a catchable
 * rejection (a static import instead crashes the whole module graph), so
 * this can fall back to a byte-for-byte reimplementation of the same
 * two-line helper. The fallback is ONLY reachable outside a real Workers
 * runtime — e.g. the local eval harness (workers/api/evals) running under
 * plain Node/tsx, where `cloudflare:workers` (a transitive dependency of
 * @cloudflare/containers) isn't available. Real Workers deployments always
 * resolve the real package below.
 */
async function getContainer(
  binding: Bindings["TWIST_BUILDER"],
  name: string
): Promise<DurableObjectStub> {
  try {
    const { getContainer: real } = await import("@cloudflare/containers");
    return real(binding, name);
  } catch {
    return binding.get(binding.idFromName(name));
  }
}

/**
 * Builds a twist from source code in an isolated container environment.
 *
 * This function:
 * 1. Gets a container instance running the twist builder server
 * 2. Sends the source code to the /build endpoint via HTTP POST
 * 3. Returns the bundled module or build errors from the server
 *
 * The container runs a Node.js server that:
 * - Creates a unique temporary directory for each build
 * - Sets up the twist project structure using the Plot CLI
 * - Writes source files and dependencies
 * - Runs npm install and plot build
 * - Cleans up the temporary directory after the build
 *
 * @param source - Twist source code containing dependencies and files
 * @param env - Bindings containing Sandbox (Container) configuration
 * @param onProgress - Optional callback for progress updates
 * @returns Promise resolving to build result (success with module or failure with errors)
 */
export async function buildTwist(
  source: TwistSource,
  env: Bindings,
  onProgress?: (message: string) => void
): Promise<BuildResult> {
  // Validate that index.ts exists
  if (!source.files["index.ts"]) {
    return {
      success: false,
      errors: ["Required file 'index.ts' is missing from source.files"],
    };
  }

  // Validate Sandbox (Container) binding
  if (!env.TWIST_BUILDER) {
    return {
      success: false,
      errors: ["Sandbox (Container) binding is not configured"],
    };
  }

  try {
    // Report progress
    onProgress?.("Building twist code");

    // Get a container instance
    // We use a consistent ID "builder" to reuse the same container instance
    // for better performance (warm starts)
    const container = await getContainer(env.TWIST_BUILDER, "builder");

    // Send build request to the container's HTTP server
    const response = await container.fetch("http://localhost:3000/build", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ...source, twisterVersion: twisterPackage.version }),
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
