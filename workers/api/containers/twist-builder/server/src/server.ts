import { exec } from "child_process";
import { randomBytes } from "crypto";
import express from "express";
import { mkdir, readFile, rm, writeFile } from "fs/promises";
import { join } from "path";
import { promisify } from "util";

import {
  getTemplate,
  InvalidVersionError,
  type TemplateResult,
} from "./templates.js";

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
  | {
      success: true;
      module: string;
      sourcemap?: string;
      templateCache?: "hit" | "miss";
    }
  | { success: false; errors: string[] };

// Resolved once per boot; used when the API doesn't pin a version
// (backward compatibility) and as the fallback when a pinned version
// can't be installed (e.g. unpublished workspace versions in dev).
let latestVersion: Promise<string> | null = null;
function resolveLatestVersion(): Promise<string> {
  latestVersion ??= execAsync("npm view @plotday/twister version", {
    timeout: 30_000,
  })
    .then((r) => r.stdout.trim())
    .catch((error) => {
      // Don't let a failed lookup poison the cache forever — clear it so
      // the next request retries instead of getting stuck on the rejection.
      latestVersion = null;
      throw error;
    });
  return latestVersion;
}

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
    const { twisterVersion, ...sourceBody } = req.body as TwistSource & {
      twisterVersion?: string;
    };
    const source = sourceBody as TwistSource;

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

    // Acquire the dependency template for the requested twister version.
    const requestedVersion = twisterVersion ?? (await resolveLatestVersion());
    let buildVersion = requestedVersion;
    let template: TemplateResult;
    try {
      template = await getTemplate(requestedVersion);
    } catch (error: any) {
      if (twisterVersion) {
        // A version that failed VALIDATION is a bad request — reject it
        // outright rather than silently building against latest.
        if (error instanceof InvalidVersionError) {
          return res.status(400).json({
            success: false,
            errors: [`Invalid twisterVersion: ${error.message}`],
          });
        }
        // Pinned version unavailable (e.g. unpublished workspace version in
        // dev) — fall back to latest rather than failing the build.
        console.warn(
          `[${twistName}] template for ${requestedVersion} failed (${error?.message}); falling back to latest`
        );
        try {
          const latest = await resolveLatestVersion();
          template = await getTemplate(latest);
          // Pin package.json to the version we actually built against —
          // otherwise a later extra-deps install still resolves the
          // (unpublished/unavailable) requested version and 404s.
          buildVersion = latest;
        } catch (fallbackError: any) {
          return res.json({
            success: false,
            errors: [
              `Failed to install dependencies:\n${fallbackError?.message ?? String(fallbackError)}`,
            ],
          });
        }
      } else {
        return res.json({
          success: false,
          errors: [
            `Failed to install dependencies:\n${error?.message ?? String(error)}`,
          ],
        });
      }
    }

    // Hardlink-copy the template's node_modules (fast); fall back to a real
    // copy if the filesystem refuses cross-links.
    console.log(`[${twistName}] Copying template (${template.cache})...`);
    try {
      await execAsync(`cp -al ${template.dir}/node_modules ${buildDir}/node_modules`);
    } catch {
      // A partial hardlink attempt can leave a half-created dest dir behind;
      // clear it first so the fallback copy can't nest node_modules/node_modules.
      await execAsync(`rm -rf ${buildDir}/node_modules`);
      await execAsync(`cp -R ${template.dir}/node_modules ${buildDir}/node_modules`);
    }
    await execAsync(`cp ${template.dir}/tsconfig.json ${buildDir}/tsconfig.json`);

    // package.json: template deps plus any extra deps the model requested.
    const extraDeps = Object.fromEntries(
      Object.entries(source.dependencies).filter(([name]) => name !== "@plotday/twister")
    );
    await writeFile(
      join(buildDir, "package.json"),
      JSON.stringify(
        {
          name: twistName,
          version: "1.0.0",
          type: "module",
          main: "src/index.ts",
          dependencies: { "@plotday/twister": buildVersion, ...extraDeps },
        },
        null,
        2
      ),
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

    // Install ONLY when the model requested extra dependencies.
    if (Object.keys(extraDeps).length > 0) {
      console.log(`[${twistName}] Installing extra dependencies: ${Object.keys(extraDeps).join(", ")}...`);
      try {
        // --ignore-scripts: per-build node_modules is only used for
        // type/bundle resolution — nothing executes from it — so lifecycle
        // scripts of model-chosen packages are pure attack surface.
        await execAsync(
          `cd ${buildDir} && npm install --no-audit --no-fund --ignore-scripts`,
          { timeout: 180_000 }
        );
      } catch (error: any) {
        return res.json({
          success: false,
          errors: [
            `Failed to install dependencies:\n${error.stderr || error.stdout || error.message}`,
          ],
        });
      }
    }

    // Type-check and bundle in parallel: a build succeeds only if both pass,
    // and failures return BOTH error sets so one retry can fix everything.
    console.log(`[${twistName}] Type-checking and bundling...`);
    const firstLines = (text: string, n: number) =>
      text.split("\n").slice(0, n).join("\n");
    const [tscError, bundleError] = await Promise.all([
      execAsync(`cd ${buildDir} && tsc -p .`, { timeout: 60_000 }).then(
        () => null,
        (e: any) => e
      ),
      execAsync(`cd ${buildDir} && plot build`, { timeout: 60_000 }).then(
        () => null,
        (e: any) => e
      ),
    ]);
    if (tscError || bundleError) {
      const errors: string[] = [];
      if (tscError) {
        errors.push(
          `Type check failed:\n${firstLines(
            tscError.stdout || tscError.stderr || tscError.message,
            80
          )}`
        );
      }
      if (bundleError) {
        errors.push(
          `Build failed:\n${bundleError.stderr || bundleError.stdout || bundleError.message}`
        );
      }
      return res.json({ success: false, errors });
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
      templateCache: template.cache,
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
