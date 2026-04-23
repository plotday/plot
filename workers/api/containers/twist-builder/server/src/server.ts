import { exec } from "child_process";
import { randomBytes } from "crypto";
import express from "express";
import { mkdir, readFile, rm, writeFile } from "fs/promises";
import { join } from "path";
import { promisify } from "util";

const execAsync = promisify(exec);

const app = express();
const PORT = 3000;

// Increase JSON payload limit for large source files
app.use(express.json({ limit: "10mb" }));

/**
 * Twist source code structure containing dependencies and source files.
 */
interface TwistSource {
  dependencies: Record<string, string>;
  files: Record<string, string>;
}

/**
 * Result from building a twist from source
 */
type BuildResult =
  | { success: true; module: string; sourcemap?: string }
  | { success: false; errors: string[] };

/**
 * Health check endpoint
 */
app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

/**
 * Build endpoint - accepts TwistSource and returns BuildResult
 */
app.post("/build", async (req, res) => {
  const startTime = Date.now();
  let buildDir: string | null = null;

  try {
    // Validate request body
    const source = req.body as TwistSource;

    if (!source || !source.files || !source.dependencies) {
      return res.status(400).json({
        success: false,
        errors: [
          "Invalid request body: must include 'files' and 'dependencies'",
        ],
      });
    }

    if (!source.files["index.ts"]) {
      return res.status(400).json({
        success: false,
        errors: ["Required file 'index.ts' is missing from source.files"],
      });
    }

    // Create unique build directory
    const timestamp = Date.now();
    const random = randomBytes(4).toString("hex");
    const twistName = `build-${timestamp}-${random}`;
    buildDir = `/tmp/twist-${timestamp}-${random}`;

    console.log(`[${twistName}] Starting build in ${buildDir}`);

    // Create the build directory
    await mkdir(buildDir, { recursive: true });

    // We write the package.json, src/, and tsconfig below — no `plot create`
    // scaffolding needed. (A previous version shelled out to `plot create` in
    // /tmp, but with a different directory name than buildDir, so everything it
    // wrote was abandoned — just ~5s of wasted work per build.)

    // Create package.json with dependencies
    const packageJson = {
      name: twistName,
      version: "1.0.0",
      type: "module",
      main: "src/index.ts",
      dependencies: source.dependencies,
    };

    console.log(`[${twistName}] Writing package.json...`);
    await writeFile(
      join(buildDir, "package.json"),
      JSON.stringify(packageJson, null, 2),
      "utf-8"
    );

    // Write all source files
    console.log(
      `[${twistName}] Writing ${
        Object.keys(source.files).length
      } source files...`
    );
    const srcDir = join(buildDir, "src");
    await mkdir(srcDir, { recursive: true });

    for (const [filename, content] of Object.entries(source.files)) {
      await writeFile(join(srcDir, filename), content, "utf-8");
    }

    // Install dependencies
    console.log(`[${twistName}] Installing dependencies...`);
    try {
      await execAsync(`cd ${buildDir} && npm install`, { timeout: 180000 });
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [
          `Failed to install dependencies:\n${
            error.stderr || error.stdout || error.message
          }`,
        ],
      });
    }

    // Build the twist
    console.log(`[${twistName}] Building twist...`);
    try {
      await execAsync(`cd ${buildDir} && plot build`, { timeout: 60000 });
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [
          `Build failed:\n${error.stderr || error.stdout || error.message}`,
        ],
      });
    }

    // Read the bundled module
    console.log(`[${twistName}] Reading bundled module...`);
    let moduleCode: string;
    try {
      moduleCode = await readFile(join(buildDir, "build", "index.js"), "utf-8");
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [`Failed to read bundled module:\n${error.message}`],
      });
    }

    // Validate the module has content
    if (moduleCode.length < 100) {
      return res.json({
        success: false,
        errors: ["Generated module is suspiciously small, likely invalid"],
      });
    }

    // Read the sourcemap if it exists
    let sourcemapCode: string | undefined;
    try {
      sourcemapCode = await readFile(
        join(buildDir, "build", "index.js.map"),
        "utf-8"
      );
      console.log(`[${twistName}] Sourcemap found and loaded`);
    } catch (error: any) {
      // Sourcemap is optional, continue without it
      console.log(`[${twistName}] No sourcemap found (this is okay)`);
    }

    const duration = Date.now() - startTime;
    console.log(`[${twistName}] Build successful in ${duration}ms`);

    // Return success with module and optional sourcemap
    res.json({
      success: true,
      module: moduleCode,
      sourcemap: sourcemapCode,
    } as BuildResult);
  } catch (error: any) {
    console.error("Build error:", error);
    res.status(500).json({
      success: false,
      errors: [
        `Build failed with exception: ${
          error instanceof Error ? error.message : JSON.stringify(error)
        }`,
      ],
    });
  } finally {
    // Clean up build directory
    if (buildDir) {
      try {
        await rm(buildDir, { recursive: true, force: true });
        console.log(`Cleaned up ${buildDir}`);
      } catch (error) {
        console.error(`Failed to clean up ${buildDir}:`, error);
      }
    }
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`Twist builder server listening on port ${PORT}`);
});
