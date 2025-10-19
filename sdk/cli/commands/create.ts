import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";
import * as out from "../utils/output";

interface CreateOptions {
  dir?: string;
  name?: string;
  displayName?: string;
}

/**
 * Detects the package manager being used
 * Checks for lock files and npm_config_user_agent
 */
function detectPackageManager(): string {
  // Check npm_config_user_agent first (set by npm, yarn, pnpm)
  const userAgent = process.env.npm_config_user_agent;
  if (userAgent) {
    if (userAgent.includes("yarn")) return "yarn";
    if (userAgent.includes("pnpm")) return "pnpm";
    if (userAgent.includes("npm")) return "npm";
  }

  // Check for lock files in current directory
  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, "pnpm-lock.yaml"))) return "pnpm";
  if (fs.existsSync(path.join(cwd, "yarn.lock"))) return "yarn";
  if (fs.existsSync(path.join(cwd, "package-lock.json"))) return "npm";

  // Default to npm
  return "npm";
}

export async function createCommand(options: CreateOptions) {
  out.header("Create a new Plot agent");

  let response: { name: string; displayName: string };

  // If both name and displayName are provided via CLI, use them directly
  if (options.name && options.displayName) {
    // Validate name
    if (!/^[a-z0-9-]+$/.test(options.name)) {
      out.error("Name must be kebab-case (lowercase, hyphens only)");
      process.exit(1);
    }

    // Validate displayName
    if (options.displayName.length === 0) {
      out.error("Display name is required");
      process.exit(1);
    }

    response = {
      name: options.name,
      displayName: options.displayName,
    };
  } else {
    // Use interactive prompts
    const promptResponse = await prompts([
      {
        type: "text",
        name: "name",
        message: "Package name:",
        initial: options.dir || options.name || undefined,
        validate: (value: string) =>
          /^[a-z0-9-]+$/.test(value) ||
          "Must be kebab-case (lowercase, hyphens only)",
      },
      {
        type: "text",
        name: "displayName",
        message: "Display name:",
        initial: options.displayName || undefined,
        validate: (value: string) => value.length > 0 || "Name is required",
      },
    ]);

    if (Object.keys(promptResponse).length === 0) {
      out.plain("\nCancelled.");
      process.exit(0);
    }

    response = promptResponse as { name: string; displayName: string };
  }

  const agentDir = options.dir || response.name;
  const agentPath = path.resolve(process.cwd(), agentDir);

  if (fs.existsSync(agentPath)) {
    out.error(`Directory "${agentDir}" already exists`);
    process.exit(1);
  }

  out.progress(`Creating ${response.displayName}...`);

  // Create directory structure
  fs.mkdirSync(agentPath, { recursive: true });
  fs.mkdirSync(path.join(agentPath, "src"), { recursive: true });

  // Read SDK version from package.json
  let sdkVersion = "^0.1.0"; // Fallback version
  try {
    const sdkPackagePath = path.join(__dirname, "..", "..", "package.json");
    const sdkPackage = JSON.parse(fs.readFileSync(sdkPackagePath, "utf-8"));
    sdkVersion = `^${sdkPackage.version}`;
  } catch (error) {
    console.warn("Warning: Could not read SDK version, using fallback");
  }

  // Generate a unique agent ID
  const plotAgentId = crypto.randomUUID();

  // Create package.json
  const packageJson: any = {
    name: response.name,
    displayName: response.displayName || response.name,
    main: "src/index.ts",
    types: "src/index.ts",
    plotAgentId: plotAgentId,
    scripts: {
      lint: "plot agent lint",
      deploy: "plot agent deploy",
    },
    dependencies: {
      "@plotday/sdk": sdkVersion,
    },
    devDependencies: {
      typescript: "^5.8.3",
    },
  };

  fs.writeFileSync(
    path.join(agentPath, "package.json"),
    JSON.stringify(packageJson, null, 2) + "\n"
  );

  // Create tsconfig.json
  const tsconfigJson = {
    extends: "@plotday/sdk/tsconfig.base.json",
    include: ["src/*.ts"],
  };
  fs.writeFileSync(
    path.join(agentPath, "tsconfig.json"),
    JSON.stringify(tsconfigJson, null, 2) + "\n"
  );

  const agentTemplate = `import {
  type Activity,
  Agent,
  type Tools,
} from "@plotday/sdk";

export default class extends Agent {
  constructor(tools: Tools) {
    super();
  }

  async activity(activity: Activity) {
    // Implement your agent logic here
    console.log("Received activity:", activity);
  }
}
`;
  fs.writeFileSync(path.join(agentPath, "src", "index.ts"), agentTemplate);

  // Detect and use appropriate package manager
  const packageManager = detectPackageManager();
  const packageManagerCommand = packageManager === "npm" ? "npm run" : packageManager;

  // Copy README.md from template
  const readmeTemplatePath = path.join(__dirname, "..", "templates", "README.template.md");
  try {
    let readmeContent = fs.readFileSync(readmeTemplatePath, "utf-8");
    // Replace template variables
    readmeContent = readmeContent.replace(/\{\{displayName\}\}/g, response.displayName);
    readmeContent = readmeContent.replace(/\{\{name\}\}/g, response.name);
    readmeContent = readmeContent.replace(/\{\{packageManager\}\}/g, packageManagerCommand);
    fs.writeFileSync(path.join(agentPath, "README.md"), readmeContent);
  } catch (error) {
    console.warn("Warning: Could not copy README template");
  }

  // Copy AGENTS.md from template
  const agentsTemplatePath = path.join(__dirname, "..", "templates", "AGENTS.template.md");
  try {
    let agentsContent = fs.readFileSync(agentsTemplatePath, "utf-8");
    // Replace template variables
    agentsContent = agentsContent.replace(/\{\{packageManager\}\}/g, packageManagerCommand);
    fs.writeFileSync(path.join(agentPath, "AGENTS.md"), agentsContent);
  } catch (error) {
    console.warn("Warning: Could not copy AGENTS template");
  }

  // Copy CLAUDE.md from template
  const claudeTemplatePath = path.join(__dirname, "..", "templates", "CLAUDE.template.md");
  try {
    const claudeContent = fs.readFileSync(claudeTemplatePath, "utf-8");
    fs.writeFileSync(path.join(agentPath, "CLAUDE.md"), claudeContent);
  } catch (error) {
    console.warn("Warning: Could not copy CLAUDE template");
  }

  // Create .gitignore
  const gitignore = `node_modules/
build/
.env
`;
  fs.writeFileSync(path.join(agentPath, ".gitignore"), gitignore);

  // Initialize git
  try {
    execSync("git init", { cwd: agentPath, stdio: "ignore" });
  } catch (error) {
    // Silently fail - not critical
  }

  const installCommand = packageManager === "yarn" ? "yarn" : `${packageManager} install`;

  // Install dependencies
  try {
    execSync(installCommand, { cwd: agentPath, stdio: "ignore" });
  } catch (error) {
    out.warning(
      "Couldn't install dependencies",
      [`Run '${installCommand}' in ${agentDir}`]
    );
  }

  out.success(`${response.displayName} created`);

  out.nextSteps([
    `cd ${agentDir}`,
    `${packageManager === "npm" ? "npm run" : packageManager} lint`,
    `${packageManager === "npm" ? "npm run" : packageManager} deploy`,
  ]);
  out.blank();
}
