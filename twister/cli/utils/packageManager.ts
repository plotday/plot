import * as fs from "fs";
import * as path from "path";

/**
 * Detects the package manager being used
 * Checks for npm_config_user_twist and lock files
 */
export function detectPackageManager(): string {
  // Check npm_config_user_twist first (set by npm, yarn, pnpm)
  const userTwist = process.env.npm_config_user_twist;
  if (userTwist) {
    if (userTwist.includes("yarn")) return "yarn";
    if (userTwist.includes("pnpm")) return "pnpm";
    if (userTwist.includes("npm")) return "npm";
  }

  // Check for lock files in current directory
  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, "pnpm-lock.yaml"))) return "pnpm";
  if (fs.existsSync(path.join(cwd, "yarn.lock"))) return "yarn";
  if (fs.existsSync(path.join(cwd, "package-lock.json"))) return "npm";

  // Default to npm
  return "npm";
}
