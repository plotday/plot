import llmDocs from "./llm-docs/index.js";

/**
 * Gets complete Agent Builder type definitions with import paths for LLM context.
 *
 * This function returns pre-generated Builder documentation that was bundled
 * at build time. Used by agent generators to provide complete type
 * information to LLMs.
 *
 * @returns Formatted string containing all Agent Builder type definitions with import paths
 */
export function getBuilderDocumentation(): string {
  let documentation = "# Plot Agent Builder Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot Agent Builder types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your agent code.\n\n";

  // Format each Builder file with headers and code fences
  for (const [importPath, content] of Object.entries(llmDocs)) {
    documentation += `## ${importPath}\n\n`;
    documentation += "```typescript\n";
    documentation += `// Import from: ${importPath}\n\n`;
    documentation += content;
    documentation += "\n```\n\n";
  }

  return documentation;
}
