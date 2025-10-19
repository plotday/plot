import express from "express";
import { exec } from "child_process";
import { promisify } from "util";
import { randomBytes } from "crypto";
import { writeFile, readFile, rm, mkdir } from "fs/promises";
import { join } from "path";

const execAsync = promisify(exec);

const app = express();
const PORT = 3000;

// Increase JSON payload limit for large source files
app.use(express.json({ limit: "10mb" }));

/**
 * Agent source code structure containing dependencies and source files.
 */
interface AgentSource {
  dependencies: Record<string, string>;
  files: Record<string, string>;
}

/**
 * Result from building an agent from source
 */
type BuildResult =
  | { success: true; module: string }
  | { success: false; errors: string[] };

/**
 * Health check endpoint
 */
app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

/**
 * Build endpoint - accepts AgentSource and returns BuildResult
 */
app.post("/build", async (req, res) => {
  const startTime = Date.now();
  let buildDir: string | null = null;

  try {
    // Validate request body
    const source = req.body as AgentSource;

    if (!source || !source.files || !source.dependencies) {
      return res.status(400).json({
        success: false,
        errors: ["Invalid request body: must include 'files' and 'dependencies'"],
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
    const agentName = `build-${timestamp}-${random}`;
    buildDir = `/tmp/agent-${timestamp}-${random}`;

    console.log(`[${agentName}] Starting build in ${buildDir}`);

    // Create the build directory
    await mkdir(buildDir, { recursive: true });

    // Create agent structure using plot CLI
    console.log(`[${agentName}] Creating agent structure...`);
    try {
      await execAsync(
        `cd /tmp && plot agent create --name ${agentName} --display-name "${agentName}"`,
        { timeout: 30000 }
      );
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [
          `Failed to create agent structure:\n${error.stderr || error.stdout || error.message}`,
        ],
      });
    }

    // Create package.json with dependencies
    const packageJson = {
      name: agentName,
      version: "1.0.0",
      type: "module",
      main: "src/index.ts",
      dependencies: source.dependencies,
    };

    console.log(`[${agentName}] Writing package.json...`);
    await writeFile(
      join(buildDir, "package.json"),
      JSON.stringify(packageJson, null, 2),
      "utf-8"
    );

    // Write all source files
    console.log(`[${agentName}] Writing ${Object.keys(source.files).length} source files...`);
    const srcDir = join(buildDir, "src");
    await mkdir(srcDir, { recursive: true });

    for (const [filename, content] of Object.entries(source.files)) {
      await writeFile(join(srcDir, filename), content, "utf-8");
    }

    // Install dependencies
    console.log(`[${agentName}] Installing dependencies...`);
    try {
      await execAsync(`cd ${buildDir} && npm install`, { timeout: 180000 });
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [
          `Failed to install dependencies:\n${error.stderr || error.stdout || error.message}`,
        ],
      });
    }

    // Build the agent
    console.log(`[${agentName}] Building agent...`);
    try {
      await execAsync(`cd ${buildDir} && plot agent build`, { timeout: 60000 });
    } catch (error: any) {
      return res.json({
        success: false,
        errors: [`Build failed:\n${error.stderr || error.stdout || error.message}`],
      });
    }

    // Read the bundled module
    console.log(`[${agentName}] Reading bundled module...`);
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

    const duration = Date.now() - startTime;
    console.log(`[${agentName}] Build successful in ${duration}ms`);

    // Return success with module
    res.json({
      success: true,
      module: moduleCode,
    } as BuildResult);
  } catch (error: any) {
    console.error("Build error:", error);
    res.status(500).json({
      success: false,
      errors: [
        `Build failed with exception: ${error instanceof Error ? error.message : JSON.stringify(error)}`,
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
  console.log(`Agent builder server listening on port ${PORT}`);
});
