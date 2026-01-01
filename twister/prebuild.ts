#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

interface TypeFile {
  file: string;
  importPath: string;
  docFilePath: string; // Path where doc file will be written (e.g., "tools/twists.ts")
  varName: string; // Valid JS identifier for imports (e.g., "toolsTwists")
}

// Generate Twister documentation files for LLM consumption
const packageJsonPath = join(__dirname, "package.json");
const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf-8"));
const srcDir = join(__dirname, "src");
const llmDocsDir = join(srcDir, "llm-docs");

// Clean and create llm-docs directory
if (existsSync(llmDocsDir)) {
  rmSync(llmDocsDir, { recursive: true });
}
mkdirSync(llmDocsDir, { recursive: true });

// Build typeFiles from package.json exports
const typeFiles: TypeFile[] = [];
const exports = packageJson.exports || {};

for (const [exportPath, exportValue] of Object.entries(exports)) {
  // Skip non-type exports and root export (to avoid circular import in index.ts)
  if (
    exportPath === "." ||
    exportPath === "./tsconfig.base.json" ||
    exportPath === "./twist-guide" ||
    exportPath === "./creator-docs" ||
    exportPath.startsWith("./llm-docs") ||
    exportPath.startsWith("./utils/")
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
    exportPath === "."
      ? "@plotday/twister"
      : `@plotday/twister${exportPath.slice(1)}`;

  // docFilePath mirrors the source file structure (e.g., "tools/twists.ts")
  // This is the path where the doc file will be written
  const docFilePath = sourceFile;

  // varName is a valid JavaScript identifier for use in index.ts imports
  // Convert path separators and hyphens to create valid identifiers
  // e.g., "tools/twists.ts" -> "toolsTwists", "common/calendar.ts" -> "commonCalendar"
  const varName = sourceFile
    .replace(/\.ts$/, "") // Remove .ts extension
    .replace(/\//g, "_") // Replace / with _
    .replace(/-/g, "_") // Replace - with _
    .replace(/^_/, ""); // Remove leading underscore if any

  typeFiles.push({ file: sourceFile, importPath, docFilePath, varName });
}

// Sort to ensure consistent ordering
typeFiles.sort((a, b) => {
  const aDepth = a.file.split("/").length;
  const bDepth = b.file.split("/").length;

  if (
    a.importPath === "@plotday/twister" &&
    b.importPath !== "@plotday/twister"
  )
    return -1;
  if (
    b.importPath === "@plotday/twister" &&
    a.importPath !== "@plotday/twister"
  )
    return 1;
  if (aDepth !== bDepth) return aDepth - bDepth;
  return a.file.localeCompare(b.file);
});

// Generate individual doc files
const indexImports: string[] = [];
const indexMappings: string[] = [];

for (const { file, importPath, docFilePath, varName } of typeFiles) {
  const sourceFilePath = join(srcDir, file);

  // Skip if source file doesn't exist
  if (!existsSync(sourceFilePath)) {
    console.warn(`Warning: Twister file not found: ${sourceFilePath}`);
    continue;
  }

  const content = readFileSync(sourceFilePath, "utf-8");

  // Create nested directory structure if needed
  const fullDocFilePath = join(llmDocsDir, docFilePath);
  const docFileDir = dirname(fullDocFilePath);
  if (!existsSync(docFileDir)) {
    mkdirSync(docFileDir, { recursive: true });
  }

  // Generate individual doc file with default export
  const docFileContent = `/**
 * Generated LLM documentation for ${importPath}
 *
 * This file is auto-generated during build. Do not edit manually.
 * Generated from: prebuild.ts
 */

export default ${JSON.stringify(content)};
`;

  writeFileSync(fullDocFilePath, docFileContent, "utf-8");

  // Add to index imports and mappings
  // Import path needs to preserve directory structure and convert .ts to .js
  const importRelativePath = docFilePath.replace(/\.ts$/, ".js");
  indexImports.push(`import ${varName} from "./${importRelativePath}";`);
  indexMappings.push(`  "${importPath}": ${varName}`);
}

// Generate index.ts with default export of mapping object
const indexContent = `/**
 * Generated LLM documentation index
 *
 * This file is auto-generated during build. Do not edit manually.
 * Generated from: prebuild.ts
 *
 * Provides a mapping of Twister import paths to their source code documentation.
 */

${indexImports.join("\n")}

const llmDocs: Record<string, string> = {
${indexMappings.join(",\n")}
};

export default llmDocs;
`;

const indexPath = join(llmDocsDir, "index.ts");
writeFileSync(indexPath, indexContent, "utf-8");

// Generate twist-guide-template.ts from AGENTS.template.md
const twistsTemplatePath = join(
  __dirname,
  "cli",
  "templates",
  "AGENTS.template.md"
);
if (existsSync(twistsTemplatePath)) {
  const twistsTemplateContent = readFileSync(twistsTemplatePath, "utf-8");
  const twistsGuideContent = `/**
 * Generated twists guide template
 *
 * This file is auto-generated during build. Do not edit manually.
 * Generated from: cli/templates/AGENTS.template.md
 */

export default ${JSON.stringify(twistsTemplateContent)};
`;
  const twistsGuideOutputPath = join(llmDocsDir, "twist-guide-template.ts");
  writeFileSync(twistsGuideOutputPath, twistsGuideContent, "utf-8");
  console.log(`✓ Generated twist-guide-template.ts from AGENTS.template.md`);
} else {
  console.warn(
    `Warning: AGENTS.template.md not found at ${twistsTemplatePath}`
  );
}

console.log(
  `✓ Generated ${typeFiles.length} LLM documentation files in src/llm-docs/`
);
