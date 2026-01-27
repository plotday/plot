import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { normalizeApiUrl } from "./url-normalize.js";

/**
 * Get the namespaced token path for a specific API URL.
 */
export function getNamespacedTokenPath(apiUrl: string): string {
  const namespace = normalizeApiUrl(apiUrl);
  const configDir =
    process.platform === "win32"
      ? process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming")
      : path.join(os.homedir(), ".config");

  return path.join(configDir, "plot", "credentials", namespace, "token");
}

/**
 * Options for token resolution.
 */
export interface TokenResolutionOptions {
  /** API URL for namespaced token lookup */
  apiUrl?: string;

  /** Token from --deploy-token CLI flag */
  deployToken?: string;

  /** Token from PLOT_DEPLOY_TOKEN env var */
  envToken?: string;

  /** Token from .env file DEPLOY_TOKEN */
  dotEnvToken?: string;
}

/**
 * Resolve token using the complete resolution chain:
 * 1. --deploy-token CLI flag
 * 2. PLOT_DEPLOY_TOKEN env var
 * 3. .env file DEPLOY_TOKEN
 * 4. Namespaced token file
 *
 * Returns undefined if no token found (caller handles prompting).
 */
export function resolveToken(
  options: TokenResolutionOptions
): string | undefined {
  // Step 1: CLI flag
  if (options.deployToken) {
    return options.deployToken;
  }

  // Step 2: PLOT_DEPLOY_TOKEN env var
  if (options.envToken) {
    return options.envToken;
  }

  // Step 3: .env file DEPLOY_TOKEN
  if (options.dotEnvToken) {
    return options.dotEnvToken;
  }

  // Step 4: Namespaced token file
  if (options.apiUrl) {
    try {
      const namespacedPath = getNamespacedTokenPath(options.apiUrl);
      if (fs.existsSync(namespacedPath)) {
        const token = fs.readFileSync(namespacedPath, "utf-8").trim();
        if (token) {
          return token;
        }
      }
    } catch (error) {
      // Invalid API URL or file read error
      console.error(`Warning: Could not read namespaced token: ${error}`);
    }
  }

  // Step 5: Prompt (handled by caller)
  return undefined;
}

/**
 * Legacy getToken() function updated to use resolveToken().
 */
export async function getToken(): Promise<string | null> {
  const token = resolveToken({
    apiUrl: process.env.PLOT_API_URL || "https://api.plot.day",
  });
  return token || null;
}
