import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

/**
 * Gets complete SDK type definitions with import paths for LLM context.
 *
 * This function reads all SDK type definition files and formats them with
 * their corresponding import paths. Used by agent generators to provide
 * complete type information to LLMs.
 *
 * @returns Formatted string containing all SDK type definitions with import paths
 */
export function getSDKDocumentation(): string {
  // Get the directory of this file
  const __filename = fileURLToPath(import.meta.url);
  const sdkRoot = path.dirname(__filename);
  const packageRoot = path.dirname(sdkRoot);

  // Read package.json to get exports dynamically
  const packageJsonPath = path.join(packageRoot, "package.json");
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf-8"));

  // Build typeFiles from package.json exports
  // Exclude non-type exports like tsconfig.base.json
  const typeFiles: Array<{ file: string; importPath: string }> = [];
  const exports = packageJson.exports || {};

  for (const [exportPath, exportValue] of Object.entries(exports)) {
    // Skip non-type exports
    if (
      exportPath === "./tsconfig.base.json" ||
      exportPath === "./agents-guide" ||
      exportPath === "./sdk-docs"
    ) {
      continue;
    }

    // Get the types field from the export
    const typesPath =
      typeof exportValue === "object" && exportValue !== null
        ? (exportValue as any).types
        : null;

    if (!typesPath || typeof typesPath !== "string") {
      continue;
    }

    // Convert dist/*.d.ts to src/*.ts
    const sourceFile = typesPath
      .replace(/^\.\/dist\//, "")
      .replace(/\.d\.ts$/, ".ts");

    // Build import path
    const importPath =
      exportPath === "." ? "@plotday/sdk" : `@plotday/sdk${exportPath.slice(1)}`;

    typeFiles.push({ file: sourceFile, importPath });
  }

  // Sort to ensure consistent ordering:
  // 1. Root exports (@plotday/sdk) first
  // 2. Then by directory depth and alphabetically
  typeFiles.sort((a, b) => {
    const aDepth = a.file.split("/").length;
    const bDepth = b.file.split("/").length;

    // Root exports first
    if (a.importPath === "@plotday/sdk" && b.importPath !== "@plotday/sdk")
      return -1;
    if (b.importPath === "@plotday/sdk" && a.importPath !== "@plotday/sdk")
      return 1;

    // Then by depth
    if (aDepth !== bDepth) return aDepth - bDepth;

    // Then alphabetically
    return a.file.localeCompare(b.file);
  });

  let documentation = "# Plot SDK Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot SDK types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your agent code.\n\n";

  for (const { file, importPath } of typeFiles) {
    const filePath = path.join(sdkRoot, file);

    // Skip if file doesn't exist (graceful degradation)
    if (!fs.existsSync(filePath)) {
      console.warn(`Warning: SDK file not found: ${filePath}`);
      continue;
    }

    const content = fs.readFileSync(filePath, "utf-8");

    documentation += `## ${importPath}\n\n`;
    documentation += "```typescript\n";
    documentation += `// Import from: ${importPath}\n\n`;
    documentation += content;
    documentation += "\n```\n\n";
  }

  return documentation;
}
