import * as fs from "fs";
import * as path from "path";

import { bundleAgent } from "../utils/bundle";
import * as out from "../utils/output";

interface BuildOptions {
  dir: string;
}

/**
 * Build command - bundles the agent without deploying.
 *
 * This command is useful for:
 * - Testing that your agent builds successfully
 * - Inspecting the bundled output
 * - CI/CD pipelines that separate build and deploy steps
 *
 * @param options - Build configuration
 */
export async function buildCommand(options: BuildOptions) {
  const agentPath = path.resolve(process.cwd(), options.dir);

  // Verify we're in an agent directory
  const packageJsonPath = path.join(agentPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    out.error(
      "package.json not found. Are you in an agent directory?",
      "Run this command from your agent's root directory"
    );
    process.exit(1);
  }

  // Read package.json for agent name
  let agentName = "agent";
  try {
    const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
    const packageJson = JSON.parse(packageJsonContent);
    agentName = packageJson.displayName || packageJson.name || "agent";
  } catch (error) {
    // Continue with default name if parsing fails
  }

  out.header(`Building ${agentName}`);

  try {
    // Bundle the agent
    out.progress("Bundling...");
    const result = await bundleAgent(agentPath, {
      minify: false,
      sourcemap: true,
    });

    // Show warnings if any
    if (result.warnings.length > 0) {
      out.warning(`Build completed with ${result.warnings.length} warning(s)`);
      for (const warning of result.warnings.slice(0, 10)) {
        console.warn(`  ${warning}`);
      }
      if (result.warnings.length > 10) {
        console.warn(`  ... and ${result.warnings.length - 10} more warnings`);
      }
    }

    // Get bundle stats
    const buildDir = path.join(agentPath, "build");
    const bundlePath = path.join(buildDir, "index.js");
    const stats = fs.statSync(bundlePath);
    const sizeKB = (stats.size / 1024).toFixed(2);

    // Show success
    out.success(`Built successfully`);
    out.plain(`  Output: ${path.relative(process.cwd(), bundlePath)}`);
    out.plain(`  Size: ${sizeKB} KB`);

    // Tip for next steps
    out.blank();
    out.plain("Next steps:");
    out.plain("  • Run 'plot deploy' to deploy this agent");
    out.plain("  • Or inspect the bundled output in build/index.js");
    out.blank();
  } catch (error) {
    out.error("Build failed", String(error));
    process.exit(1);
  }
}
