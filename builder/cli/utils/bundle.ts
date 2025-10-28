import * as esbuild from "esbuild";
import * as fs from "fs";
import * as path from "path";

export interface BundleOptions {
  minify?: boolean;
  sourcemap?: boolean;
}

export interface BundleResult {
  code: string;
  sourcemap?: string;
  warnings: string[];
}

/**
 * Bundles a Plot agent using esbuild.
 *
 * This function is shared between the build and deploy commands to ensure
 * consistent bundling behavior.
 *
 * @param agentPath - Absolute path to the agent directory
 * @param options - Optional bundling configuration
 * @returns Promise resolving to the bundled code and any warnings
 * @throws Error if bundling fails
 */
export async function bundleAgent(
  agentPath: string,
  options: BundleOptions = {}
): Promise<BundleResult> {
  const { minify = false, sourcemap = true } = options;

  // Validate agent path exists
  if (!fs.existsSync(agentPath)) {
    throw new Error(`Agent directory not found: ${agentPath}`);
  }

  // Check for entry point
  const entryPoint = path.join(agentPath, "src", "index.ts");
  if (!fs.existsSync(entryPoint)) {
    throw new Error(
      "src/index.ts not found. Your agent needs an entry point at src/index.ts"
    );
  }

  // Create build directory
  const buildDir = path.join(agentPath, "build");
  if (fs.existsSync(buildDir)) {
    fs.rmSync(buildDir, { recursive: true });
  }
  fs.mkdirSync(buildDir, { recursive: true });

  // Bundle with esbuild
  const result = await esbuild.build({
    entryPoints: [entryPoint],
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "esnext",
    outfile: path.join(buildDir, "index.js"),
    sourcemap,
    minify,
    logLevel: "silent",
  });

  // Check for errors
  if (result.errors.length > 0) {
    const errorMessages = result.errors
      .map((err) => `${err.location?.file}:${err.location?.line} - ${err.text}`)
      .join("\n");
    throw new Error(`Build failed with errors:\n${errorMessages}`);
  }

  // Collect warnings
  const warnings = result.warnings.map(
    (warn) =>
      `${warn.location?.file}:${warn.location?.line} - ${warn.text}`
  );

  // Read the bundled code
  const bundlePath = path.join(buildDir, "index.js");
  const code = fs.readFileSync(bundlePath, "utf-8");

  // Read the sourcemap if it exists
  let sourcemapContent: string | undefined;
  if (sourcemap) {
    const sourcemapPath = path.join(buildDir, "index.js.map");
    if (fs.existsSync(sourcemapPath)) {
      sourcemapContent = fs.readFileSync(sourcemapPath, "utf-8");
    }
  }

  return {
    code,
    sourcemap: sourcemapContent,
    warnings,
  };
}
