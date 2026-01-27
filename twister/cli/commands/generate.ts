import { execSync } from "child_process";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import { handleNetworkError } from "../utils/network-error";
import * as out from "../utils/output";
import { detectPackageManager } from "../utils/packageManager";
import { handleSSEStream } from "../utils/sse";
import { resolveToken } from "../utils/token.js";

interface GenerateOptions {
  dir: string;
  spec?: string;
  id?: string;
  deployToken?: string;
  apiUrl: string;
}

interface TwistSource {
  displayName: string;
  dependencies: Record<string, string>;
  files: Record<string, string>;
}

/**
 * Check if files exist and prompt to overwrite
 */
async function promptOverwrite(
  files: string[]
): Promise<{ overwrite: boolean; skip: Set<string> }> {
  const existingFiles = files.filter((file) => fs.existsSync(file));

  if (existingFiles.length === 0) {
    return { overwrite: true, skip: new Set() };
  }

  out.warning(
    `${existingFiles.length} file(s) already exist`,
    existingFiles.map((file) => path.basename(file))
  );

  const response = await prompts({
    type: "select",
    name: "action",
    message: "What would you like to do?",
    choices: [
      { title: "Overwrite all", value: "overwrite" },
      { title: "Skip existing files", value: "skip" },
      { title: "Cancel generation", value: "cancel" },
    ],
  });

  if (response.action === "cancel") {
    out.plain("\nGeneration cancelled.");
    process.exit(0);
  }

  if (response.action === "skip") {
    return { overwrite: false, skip: new Set(existingFiles) };
  }

  return { overwrite: true, skip: new Set() };
}

export async function generateCommand(options: GenerateOptions) {
  const twistPath = path.resolve(process.cwd(), options.dir);

  // Determine spec file path (default to plot-twist.md)
  const specPath = options.spec
    ? path.resolve(process.cwd(), options.spec)
    : path.join(twistPath, "plot-twist.md");

  // Check if spec file exists
  if (!fs.existsSync(specPath)) {
    out.error(
      `Spec file not found: ${path.relative(process.cwd(), specPath)}`,
      "Create a plot-twist.md file describing your twist, or use --spec to specify a different file"
    );
    process.exit(1);
  }

  // Read spec content
  let specContent: string;
  try {
    specContent = fs.readFileSync(specPath, "utf-8");
  } catch (error) {
    out.error("Failed to read spec file", String(error));
    process.exit(1);
  }

  // Try to read package.json for twist ID
  const packageJsonPath = path.join(twistPath, "package.json");
  let twistId = options.id;

  if (!twistId && fs.existsSync(packageJsonPath)) {
    try {
      const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf-8"));
      twistId = packageJson.plotTwistId;
    } catch {
      // Ignore errors
    }
  }

  // Generate twist ID if not provided
  if (!twistId) {
    twistId = crypto.randomUUID();
  }

  // Load DEPLOY_TOKEN from multiple sources (CLI, env var, .env, namespaced token file)
  const envPath = path.join(twistPath, ".env");

  // Read .env file if it exists
  let dotEnvToken: string | undefined;
  if (fs.existsSync(envPath)) {
    const envConfig = dotenv.parse(fs.readFileSync(envPath));
    dotEnvToken = envConfig.DEPLOY_TOKEN;
  }

  // Resolve token using centralized function
  let deployToken = resolveToken({
    apiUrl: options.apiUrl,
    deployToken: options.deployToken,
    envToken: process.env.PLOT_DEPLOY_TOKEN,
    dotEnvToken: dotEnvToken,
  });

  // Prompt for token if not found
  if (!deployToken) {
    out.info("Authentication required", [
      "Run 'plot login' for easiest setup",
      "Or provide token via --deploy-token, PLOT_DEPLOY_TOKEN env var, or DEPLOY_TOKEN in .env",
    ]);

    const response = await prompts({
      type: "password",
      name: "token",
      message: "Enter your deployment token:",
      validate: (value: string) => value.length > 0 || "Token is required",
    });

    if (!response.token) {
      out.plain("\nGeneration cancelled.");
      process.exit(0);
    }

    deployToken = response.token;

    // Save token to .env file for future use
    const envContent = fs.existsSync(envPath)
      ? fs.readFileSync(envPath, "utf-8")
      : "";

    if (!envContent.includes("DEPLOY_TOKEN=")) {
      const newEnvContent =
        envContent +
        (envContent.endsWith("\n") || !envContent ? "" : "\n") +
        `DEPLOY_TOKEN=${deployToken}\n`;
      fs.writeFileSync(envPath, newEnvContent);
      out.success("Token saved to .env file");
    }
  }

  // Call generate API
  try {
    const relativeSpecPath = path.relative(process.cwd(), specPath);
    out.progress(`Generate twist from ${relativeSpecPath}...`);

    const response = await fetch(`${options.apiUrl}/v1/twist/generate`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        Authorization: `Bearer ${deployToken}`,
      },
      body: JSON.stringify({ spec: specContent }),
    });

    if (!response.ok) {
      if (response.status === 401) {
        out.error(
          "Authentication failed",
          "Your login token is invalid or has expired. Please run 'plot login' to authenticate."
        );
        process.exit(1);
      }
      const errorText = await response.text();
      out.error("Generation failed", errorText);
      process.exit(1);
    }

    // Handle SSE stream with progress updates
    const source = (await handleSSEStream(response, {
      onProgress: (message) => {
        out.progress(message);
      },
    })) as TwistSource;

    // Create twist directory if it doesn't exist
    if (!fs.existsSync(twistPath)) {
      fs.mkdirSync(twistPath, { recursive: true });
    }

    // Prepare list of files that will be created
    const packageJsonPath = path.join(twistPath, "package.json");
    const tsconfigPath = path.join(twistPath, "tsconfig.json");
    const readmePath = path.join(twistPath, "README.md");
    const twistsMdPath = path.join(twistPath, "AGENTS.md");
    const claudeMdPath = path.join(twistPath, "CLAUDE.md");

    const srcPath = path.join(twistPath, "src");
    const sourceFiles = Object.keys(source.files).map((filename) =>
      path.join(srcPath, filename)
    );

    const allFiles = [
      packageJsonPath,
      tsconfigPath,
      readmePath,
      twistsMdPath,
      claudeMdPath,
      ...sourceFiles,
    ];

    // Check for existing files and prompt to overwrite
    const { skip } = await promptOverwrite(allFiles);

    // Helper to write file if not skipped
    const writeFile = (filePath: string, content: string) => {
      if (!skip.has(filePath)) {
        fs.writeFileSync(filePath, content);
        out.success(`Created ${path.relative(twistPath, filePath)}`);
      } else {
        out.info(`Skipped ${path.relative(twistPath, filePath)}`);
      }
    };

    // Write package.json
    const packageJson = {
      name: twistId,
      version: "1.0.0",
      displayName: source.displayName,
      plotTwistId: twistId,
      scripts: {
        lint: "plot lint",
        deploy: "plot deploy",
        logs: "plot logs",
      },
      dependencies: source.dependencies,
      devDependencies: {
        typescript: "latest",
      },
    };
    writeFile(packageJsonPath, JSON.stringify(packageJson, null, 2) + "\n");

    // Write tsconfig.json
    const tsconfigContent = {
      extends: "@plotday/twister/tsconfig.base.json",
      include: ["src/*.ts"],
    };
    writeFile(tsconfigPath, JSON.stringify(tsconfigContent, null, 2) + "\n");

    // Load and write template files
    const templatesPath = path.join(__dirname, "..", "..", "bin", "templates");

    // Write AGENTS.md (no template processing needed)
    const twistsMdTemplate = fs.readFileSync(
      path.join(templatesPath, "AGENTS.template.md"),
      "utf-8"
    );
    writeFile(twistsMdPath, twistsMdTemplate);

    // Write CLAUDE.md (no template processing needed)
    const claudeMdTemplate = fs.readFileSync(
      path.join(templatesPath, "CLAUDE.template.md"),
      "utf-8"
    );
    writeFile(claudeMdPath, claudeMdTemplate);

    // Write README.md with template replacements
    let readmeTemplate = fs.readFileSync(
      path.join(templatesPath, "README.template.md"),
      "utf-8"
    );
    // Replace template variables
    readmeTemplate = readmeTemplate.replace(
      /\{\{displayName\}\}/g,
      source.displayName
    );
    readmeTemplate = readmeTemplate.replace(/\{\{packageManager\}\}/g, "pnpm");
    writeFile(readmePath, readmeTemplate);

    // Create src directory
    if (!fs.existsSync(srcPath)) {
      fs.mkdirSync(srcPath, { recursive: true });
    }

    // Write source files
    for (const [filename, content] of Object.entries(source.files)) {
      const filePath = path.join(srcPath, filename);
      writeFile(filePath, content);
    }

    out.blank();

    // Detect package manager and install dependencies
    const packageManager = detectPackageManager();

    // Update @plotday/twist to latest and install packages
    try {
      out.progress("Updating Twist Creator to latest version...");

      const updateCommand =
        packageManager === "npm"
          ? "npm install @plotday/twist@latest"
          : packageManager === "pnpm"
          ? "pnpm add @plotday/twist@latest"
          : "yarn add @plotday/twist@latest";

      execSync(updateCommand, { cwd: twistPath, stdio: "ignore" });

      out.progress("Installing dependencies...");

      const installCommand =
        packageManager === "yarn" ? "yarn" : `${packageManager} install`;

      execSync(installCommand, { cwd: twistPath, stdio: "ignore" });

      out.success("Dependencies installed.");
    } catch (error) {
      out.warning("Couldn't install dependencies", [
        `Run '${packageManager} install @plotday/twist@latest' in ${options.dir}`,
        `Then run '${
          packageManager === "yarn" ? "yarn" : `${packageManager} install`
        }'`,
      ]);
    }

    out.blank();
    out.success("Twist generated successfully!");

    out.nextSteps([
      "Review the generated code in src/",
      `Run '${packageManager} run deploy' to deploy your twist`,
      `Run '${packageManager} run logs' to watch for activity`,
    ]);
  } catch (error) {
    const errorInfo = handleNetworkError(error);
    out.error("Generation failed", errorInfo.message);
    if (errorInfo.details) {
      console.error(out.colors.dim(errorInfo.details));
    }
    process.exit(1);
  }
}
