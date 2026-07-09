import llmDocs from "./llm-docs/index.js";
import twistExemplars from "./llm-docs/twist-exemplars.js";

/**
 * Gets complete Twist Creator type definitions with import paths for LLM context.
 *
 * This function returns pre-generated Builder documentation that was bundled
 * at build time. Used by twist generators to provide complete type
 * information to LLMs.
 *
 * @returns Formatted string containing all Twist Creator type definitions with import paths
 */
export function getBuilderDocumentation(): string {
  let documentation = "# Plot Twist Creator Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot Twist Creator types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your twist code.\n\n";

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

// Modules excluded from TWIST generation docs: twists must never extend
// Connector, and the mail-protocol tools are niche enough to dilute the
// prompt more than they help.
const TWIST_DOC_EXCLUSIONS = new Set([
  "@plotday/twister/connector",
  "@plotday/twister/tools/imap",
  "@plotday/twister/tools/smtp",
]);

/**
 * Twist-scoped variant of getBuilderDocumentation(): the same formatted
 * type definitions, minus modules that are irrelevant (or misleading) when
 * generating a twist.
 */
export function getTwistDocumentation(): string {
  let documentation = "# Plot Twist Creator Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot Twist Creator types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your twist code.\n\n";
  for (const [importPath, content] of Object.entries(llmDocs)) {
    if (TWIST_DOC_EXCLUSIONS.has(importPath)) continue;
    documentation += `## ${importPath}\n\n`;
    documentation += "```typescript\n";
    documentation += `// Import from: ${importPath}\n\n`;
    documentation += content;
    documentation += "\n```\n\n";
  }
  return documentation;
}

/**
 * Complete example twists (specification + implementation pairs) for LLM
 * generation prompts. The examples are real compiled sources in
 * src/exemplars/, so they are type-checked on every build.
 */
export const TWIST_EXEMPLARS: string = twistExemplars;
