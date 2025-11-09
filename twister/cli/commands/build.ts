import * as fs from "fs";
import * as path from "path";

import { bundleTwist } from "../utils/bundle";
import * as out from "../utils/output";

interface BuildOptions {
  dir: string;
}

/**
 * Build command - bundles the twist without deploying.
 *
 * This command is useful for:
 * - Testing that your twist builds successfully
 * - Inspecting the bundled output
 * - CI/CD pipelines that separate build and deploy steps
 *
 * @param options - Build configuration
 */
export async function buildCommand(options: BuildOptions) {
  const twistPath = path.resolve(process.cwd(), options.dir);

  // Verify we're in an twist directory
  const packageJsonPath = path.join(twistPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    out.error(
      "package.json not found. Are you in an twist directory?",
      "Run this command from your twist's root directory"
    );
    process.exit(1);
  }

  // Read package.json for twist name
  let twistName = "twist";
  try {
    const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
    const packageJson = JSON.parse(packageJsonContent);
    twistName = packageJson.displayName || packageJson.name || "twist";
  } catch (error) {
    // Continue with default name if parsing fails
  }

  out.header(`Building ${twistName}`);

  try {
    // Bundle the twist
    out.progress("Bundling...");
    const result = await bundleTwist(twistPath, {
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
    const buildDir = path.join(twistPath, "build");
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
    out.plain("  • Run 'plot deploy' to deploy this twist");
    out.plain("  • Or inspect the bundled output in build/index.js");
    out.blank();
  } catch (error) {
    out.error("Build failed", String(error));
    process.exit(1);
  }
}
