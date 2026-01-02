import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

import * as out from "./output";

export interface TypeCheckError {
  packageName: string;
  packagePath: string;
  error: string;
}

export interface TypeCheckResult {
  success: boolean;
  errors: TypeCheckError[];
}

/**
 * Resolves a workspace package name to its monorepo path.
 *
 * @param packageName - Package name like "@plotday/tool-linear" or "@plotday/twister"
 * @param twistPath - Absolute path to the twist directory
 * @returns Absolute path to the package directory, or null if not resolvable
 */
function resolveWorkspacePackagePath(
  packageName: string,
  twistPath: string
): string | null {
  // Determine the monorepo root (public directory)
  // From twist path like /path/to/public/twists/project-sync
  // Go up two levels to /path/to/public
  const monorepoRoot = path.resolve(twistPath, "../..");

  if (packageName === "@plotday/twister") {
    return path.join(monorepoRoot, "twister");
  }

  // Extract the package name without scope
  // @plotday/tool-linear -> tool-linear
  // @plotday/twist-something -> twist-something
  const match = packageName.match(/@plotday\/(tool|twist)-(.+)/);
  if (!match) {
    return null;
  }

  const [, type, name] = match;
  const packagePath = path.join(monorepoRoot, `${type}s`, name ?? "");

  return packagePath;
}

/**
 * Checks TypeScript types for all workspace dependencies of a twist.
 *
 * This function:
 * 1. Reads the twist's package.json
 * 2. Finds all dependencies using the workspace: protocol
 * 3. Resolves each to its monorepo path
 * 4. Runs `tsc --noEmit` in each dependency directory
 * 5. Reports any type errors
 *
 * @param twistPath - Absolute path to the twist directory
 * @returns TypeCheckResult with success status and any errors found
 */
export function checkWorkspaceDependencies(twistPath: string): TypeCheckResult {
  const errors: TypeCheckError[] = [];

  // Read package.json
  const packageJsonPath = path.join(twistPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    return {
      success: true,
      errors: [],
    };
  }

  let packageJson: any;
  try {
    const content = fs.readFileSync(packageJsonPath, "utf-8");
    packageJson = JSON.parse(content);
  } catch (error) {
    errors.push({
      packageName: "package.json",
      packagePath: twistPath,
      error: `Failed to parse package.json: ${error}`,
    });
    return {
      success: false,
      errors,
    };
  }

  // Find workspace dependencies
  const allDependencies = {
    ...packageJson.dependencies,
    ...packageJson.devDependencies,
  };

  const workspaceDeps = Object.entries(allDependencies).filter(
    ([, version]) =>
      typeof version === "string" && version.startsWith("workspace:")
  );

  if (workspaceDeps.length === 0) {
    return {
      success: true,
      errors: [],
    };
  }

  // Type-check each workspace dependency
  for (const [packageName] of workspaceDeps) {
    // Skip twister itself - it's the SDK, not a tool/twist
    if (packageName === "@plotday/twister") {
      continue;
    }

    const packagePath = resolveWorkspacePackagePath(packageName, twistPath);
    if (!packagePath) {
      errors.push({
        packageName,
        packagePath: "",
        error: "Could not resolve workspace package path",
      });
      continue;
    }

    if (!fs.existsSync(packagePath)) {
      errors.push({
        packageName,
        packagePath,
        error: "Package directory not found",
      });
      continue;
    }

    // Check if the package has a tsconfig.json
    const tsconfigPath = path.join(packagePath, "tsconfig.json");
    if (!fs.existsSync(tsconfigPath)) {
      // No tsconfig means no TypeScript to check, skip silently
      continue;
    }

    // Run tsc --noEmit to type-check
    try {
      execSync("tsc --noEmit", {
        cwd: packagePath,
        stdio: "pipe", // Capture output instead of inheriting
        encoding: "utf-8",
      });
    } catch (error: any) {
      // execSync throws if the command exits with non-zero
      // The error contains stdout/stderr with the TypeScript errors
      const errorOutput = error.stdout || error.stderr || error.message;
      errors.push({
        packageName,
        packagePath,
        error: errorOutput,
      });
    }
  }

  return {
    success: errors.length === 0,
    errors,
  };
}

/**
 * Checks workspace dependencies and displays results.
 * Exits the process if any errors are found.
 *
 * @param twistPath - Absolute path to the twist directory
 */
export function checkAndReportWorkspaceDependencies(twistPath: string): void {
  const workspaceDepCount = getWorkspaceDependencyCount(twistPath);

  if (workspaceDepCount === 0) {
    // No workspace dependencies to check
    return;
  }

  out.progress(
    `Checking types in ${workspaceDepCount} workspace ${
      workspaceDepCount === 1 ? "dependency" : "dependencies"
    }...`
  );

  const result = checkWorkspaceDependencies(twistPath);

  if (!result.success) {
    out.error("Type errors found in workspace dependencies");
    out.blank();

    for (const error of result.errors) {
      console.error(out.colors.error(`✗ ${error.packageName}`));
      console.error(out.colors.dim(`  ${error.packagePath}`));
      console.error();
      // Print the actual TypeScript errors
      console.error(error.error);
      console.error();
    }

    process.exit(1);
  }

  out.success(`Workspace dependencies type-checked successfully`);
}

/**
 * Counts the number of workspace dependencies (excluding @plotday/twister).
 */
function getWorkspaceDependencyCount(twistPath: string): number {
  const packageJsonPath = path.join(twistPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    return 0;
  }

  try {
    const content = fs.readFileSync(packageJsonPath, "utf-8");
    const packageJson = JSON.parse(content);

    const allDependencies = {
      ...packageJson.dependencies,
      ...packageJson.devDependencies,
    };

    const workspaceDeps = Object.entries(allDependencies).filter(
      ([name, version]) =>
        typeof version === "string" &&
        version.startsWith("workspace:") &&
        name !== "@plotday/twister" // Exclude twister itself
    );

    return workspaceDeps.length;
  } catch {
    return 0;
  }
}
