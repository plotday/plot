import { execSync } from "child_process";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import * as out from "../utils/output";
import { detectPackageManager } from "../utils/packageManager";
import { handleSSEStream } from "../utils/sse";
import { getGlobalTokenPath } from "../utils/token";

interface GenerateOptions {
  dir: string;
  spec?: string;
  id?: string;
  deployToken?: string;
  apiUrl: string;
}

interface AgentSource {
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
  const agentPath = path.resolve(process.cwd(), options.dir);

  // Determine spec file path (default to plot-agent.md)
  const specPath = options.spec
    ? path.resolve(process.cwd(), options.spec)
    : path.join(agentPath, "plot-agent.md");

  // Check if spec file exists
  if (!fs.existsSync(specPath)) {
    out.error(
      `Spec file not found: ${path.relative(process.cwd(), specPath)}`,
      "Create a plot-agent.md file describing your agent, or use --spec to specify a different file"
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

  // Try to read package.json for agent ID
  const packageJsonPath = path.join(agentPath, "package.json");
  let agentId = options.id;

  if (!agentId && fs.existsSync(packageJsonPath)) {
    try {
      const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf-8"));
      agentId = packageJson.plotAgentId;
    } catch {
      // Ignore errors
    }
  }

  // Generate agent ID if not provided
  if (!agentId) {
    agentId = crypto.randomUUID();
  }

  // Load DEPLOY_TOKEN from multiple sources
  let deployToken = options.deployToken;
  const envPath = path.join(agentPath, ".env");

  if (!deployToken) {
    deployToken = process.env.PLOT_DEPLOY_TOKEN;
  }

  if (!deployToken && fs.existsSync(envPath)) {
    const envConfig = dotenv.parse(fs.readFileSync(envPath));
    deployToken = envConfig.DEPLOY_TOKEN;
  }

  if (!deployToken) {
    const globalTokenPath = getGlobalTokenPath();
    if (fs.existsSync(globalTokenPath)) {
      try {
        deployToken = fs.readFileSync(globalTokenPath, "utf-8").trim();
      } catch (error) {
        console.warn(
          `Warning: Failed to read global token file: ${globalTokenPath}`
        );
      }
    }
  }

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
    out.progress(`Generate agent from ${relativeSpecPath}...`);

    const response = await fetch(`${options.apiUrl}/v1/agent/generate`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        Authorization: `Bearer ${deployToken}`,
      },
      body: JSON.stringify({ spec: specContent }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      out.error(
        `Generation failed: ${response.status} ${response.statusText}`,
        errorText
      );
      process.exit(1);
    }

    // Handle SSE stream with progress updates
    const source = (await handleSSEStream(response, {
      onProgress: (message) => {
        out.progress(message);
      },
    })) as AgentSource;

    // Create agent directory if it doesn't exist
    if (!fs.existsSync(agentPath)) {
      fs.mkdirSync(agentPath, { recursive: true });
    }

    // Prepare list of files that will be created
    const packageJsonPath = path.join(agentPath, "package.json");
    const tsconfigPath = path.join(agentPath, "tsconfig.json");
    const readmePath = path.join(agentPath, "README.md");
    const agentsMdPath = path.join(agentPath, "AGENTS.md");
    const claudeMdPath = path.join(agentPath, "CLAUDE.md");

    const srcPath = path.join(agentPath, "src");
    const sourceFiles = Object.keys(source.files).map((filename) =>
      path.join(srcPath, filename)
    );

    const allFiles = [
      packageJsonPath,
      tsconfigPath,
      readmePath,
      agentsMdPath,
      claudeMdPath,
      ...sourceFiles,
    ];

    // Check for existing files and prompt to overwrite
    const { skip } = await promptOverwrite(allFiles);

    // Helper to write file if not skipped
    const writeFile = (filePath: string, content: string) => {
      if (!skip.has(filePath)) {
        fs.writeFileSync(filePath, content);
        out.success(`Created ${path.relative(agentPath, filePath)}`);
      } else {
        out.info(`Skipped ${path.relative(agentPath, filePath)}`);
      }
    };

    // Write package.json
    const packageJson = {
      name: agentId,
      version: "1.0.0",
      displayName: source.displayName,
      plotAgentId: agentId,
      scripts: {
        lint: "plot agent lint",
        deploy: "plot agent deploy",
        logs: "plot agent logs",
      },
      dependencies: source.dependencies,
      devDependencies: {
        typescript: "latest",
      },
    };
    writeFile(packageJsonPath, JSON.stringify(packageJson, null, 2) + "\n");

    // Write tsconfig.json
    const tsconfigContent = {
      extends: "@plotday/agent/tsconfig.base.json",
      include: ["src/*.ts"],
    };
    writeFile(tsconfigPath, JSON.stringify(tsconfigContent, null, 2) + "\n");

    // Load and write template files
    const templatesPath = path.join(__dirname, "..", "..", "bin", "templates");

    // Write AGENTS.md (no template processing needed)
    const agentsMdTemplate = fs.readFileSync(
      path.join(templatesPath, "AGENTS.template.md"),
      "utf-8"
    );
    writeFile(agentsMdPath, agentsMdTemplate);

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

    // Update @plotday/agent to latest and install packages
    try {
      out.progress("Updating Agent Builder to latest version...");

      const updateCommand =
        packageManager === "npm"
          ? "npm install @plotday/agent@latest"
          : packageManager === "pnpm"
          ? "pnpm add @plotday/agent@latest"
          : "yarn add @plotday/agent@latest";

      execSync(updateCommand, { cwd: agentPath, stdio: "ignore" });

      out.progress("Installing dependencies...");

      const installCommand =
        packageManager === "yarn" ? "yarn" : `${packageManager} install`;

      execSync(installCommand, { cwd: agentPath, stdio: "ignore" });

      out.success("Dependencies installed.");
    } catch (error) {
      out.warning("Couldn't install dependencies", [
        `Run '${packageManager} install @plotday/agent@latest' in ${options.dir}`,
        `Then run '${
          packageManager === "yarn" ? "yarn" : `${packageManager} install`
        }'`,
      ]);
    }

    out.blank();
    out.success("Agent generated successfully!");

    out.nextSteps([
      "Review the generated code in src/",
      `Run '${packageManager} run deploy' to deploy your agent`,
      `Run '${packageManager} run logs' to watch for activity`,
    ]);
  } catch (error) {
    out.error("Generation failed", String(error));
    process.exit(1);
  }
}
