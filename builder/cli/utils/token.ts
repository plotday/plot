import * as fs from "fs";
import * as os from "os";
import * as path from "path";

/**
 * Get the path to the global token file.
 *
 * @returns The path to the global token file
 */
export function getGlobalTokenPath(): string {
  const homeDir = os.homedir();
  if (process.platform === "win32") {
    // Windows: Use APPDATA
    const appData = process.env.APPDATA || path.join(homeDir, "AppData", "Roaming");
    return path.join(appData, "plot", "token");
  } else {
    // Unix-like: Use ~/.config/plot/token
    return path.join(homeDir, ".config", "plot", "token");
  }
}

/**
 * Read the authentication token from the global token file.
 *
 * @returns The token string if found, null otherwise
 */
export async function getToken(): Promise<string | null> {
  const globalTokenPath = getGlobalTokenPath();
  if (fs.existsSync(globalTokenPath)) {
    try {
      return fs.readFileSync(globalTokenPath, "utf-8").trim();
    } catch (error) {
      console.warn(
        `Warning: Failed to read global token file: ${globalTokenPath}`
      );
    }
  }
  return null;
}
