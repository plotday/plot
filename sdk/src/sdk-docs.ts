import llmDocs from "./llm-docs/index.js";

/**
 * Gets complete SDK type definitions with import paths for LLM context.
 *
 * This function returns pre-generated SDK documentation that was bundled
 * at build time. Used by agent generators to provide complete type
 * information to LLMs.
 *
 * @returns Formatted string containing all SDK type definitions with import paths
 */
export function getSDKDocumentation(): string {
  let documentation = "# Plot SDK Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot SDK types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your agent code.\n\n";

  // Format each SDK file with headers and code fences
  for (const [importPath, content] of Object.entries(llmDocs)) {
    documentation += `## ${importPath}\n\n`;
    documentation += "```typescript\n";
    documentation += `// Import from: ${importPath}\n\n`;
    documentation += content;
    documentation += "\n```\n\n";
  }

  return documentation;
}
