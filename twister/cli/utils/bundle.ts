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
 * Bundles a Plot twist using esbuild.
 *
 * This function is shared between the build and deploy commands to ensure
 * consistent bundling behavior.
 *
 * @param twistPath - Absolute path to the twist directory
 * @param options - Optional bundling configuration
 * @returns Promise resolving to the bundled code and any warnings
 * @throws Error if bundling fails
 */
export async function bundleTwist(
  twistPath: string,
  options: BundleOptions = {}
): Promise<BundleResult> {
  const { minify = false, sourcemap = true } = options;

  // Validate twist path exists
  if (!fs.existsSync(twistPath)) {
    throw new Error(`Twist directory not found: ${twistPath}`);
  }

  // Check for entry point
  const entryPoint = path.join(twistPath, "src", "index.ts");
  if (!fs.existsSync(entryPoint)) {
    throw new Error(
      "src/index.ts not found. Your twist needs an entry point at src/index.ts"
    );
  }

  // Create build directory
  const buildDir = path.join(twistPath, "build");
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
    // Mark Node.js built-ins as external - they'll be provided by Cloudflare Workers' nodejs_compat
    external: [
      "node:*",
      "buffer",
      "events",
      "stream",
      "util",
      "http",
      "https",
      "url",
      "zlib",
      "crypto",
      "path",
      "fs",
      "os",
      "net",
      "tls",
      "dns",
      "dgram",
      "child_process",
      "cluster",
      "readline",
      "repl",
      "tty",
      "vm",
      "querystring",
      "string_decoder",
      "punycode",
      "process",
      "assert",
      "constants",
      "module",
      "perf_hooks",
      "worker_threads",
      "async_hooks",
      "timers",
      "inspector",
      "v8",
    ],
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
