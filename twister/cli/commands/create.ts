import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import * as out from "../utils/output";
import { detectPackageManager } from "../utils/packageManager";

interface CreateOptions {
  dir?: string;
  name?: string;
  displayName?: string;
}

export async function createCommand(options: CreateOptions) {
  out.header("Create a new Plot twist");

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

  const twistDir = options.dir || response.name;
  const twistPath = path.resolve(process.cwd(), twistDir);

  if (fs.existsSync(twistPath)) {
    out.error(`Directory "${twistDir}" already exists`);
    process.exit(1);
  }

  out.progress(`Creating ${response.displayName}...`);

  // Create directory structure
  fs.mkdirSync(twistPath, { recursive: true });
  fs.mkdirSync(path.join(twistPath, "src"), { recursive: true });

  // Read SDK version from package.json
  let sdkVersion = "^0.1.0"; // Fallback version
  try {
    const sdkPackagePath = path.join(__dirname, "..", "..", "package.json");
    const sdkPackage = JSON.parse(fs.readFileSync(sdkPackagePath, "utf-8"));
    sdkVersion = `^${sdkPackage.version}`;
  } catch (error) {
    console.warn(
      "Warning: Could not read Twist Creator version, using fallback"
    );
  }

  // Generate a unique twist ID
  const plotTwistId = crypto.randomUUID();

  // Create package.json
  const packageJson: any = {
    name: response.name,
    displayName: response.displayName || response.name,
    main: "src/index.ts",
    types: "src/index.ts",
    plotTwistId: plotTwistId,
    scripts: {
      lint: "plot lint",
      deploy: "plot deploy",
    },
    dependencies: {
      "@plotday/twister": sdkVersion,
    },
    devDependencies: {
      typescript: "^5.8.3",
    },
  };

  fs.writeFileSync(
    path.join(twistPath, "package.json"),
    JSON.stringify(packageJson, null, 2) + "\n"
  );

  // Create tsconfig.json
  const tsconfigJson = {
    extends: "@plotday/twister/tsconfig.base.json",
    include: ["src/*.ts"],
  };
  fs.writeFileSync(
    path.join(twistPath, "tsconfig.json"),
    JSON.stringify(tsconfigJson, null, 2) + "\n"
  );

  const twistTemplate = `import {
  type Activity,
  Twist,
  type Priority,
  type ToolBuilder,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Called when twist is enabled for a priority
  }

  async activity(activity: Activity) {
    // Called when an activity is routed to this twist
  }
}
`;
  fs.writeFileSync(path.join(twistPath, "src", "index.ts"), twistTemplate);

  // Detect and use appropriate package manager
  const packageManager = detectPackageManager();
  const packageManagerCommand =
    packageManager === "npm" ? "npm run" : packageManager;

  // Copy README.md from template
  const readmeTemplatePath = path.join(
    __dirname,
    "..",
    "templates",
    "README.template.md"
  );
  try {
    let readmeContent = fs.readFileSync(readmeTemplatePath, "utf-8");
    // Replace template variables
    readmeContent = readmeContent.replace(
      /\{\{displayName\}\}/g,
      response.displayName
    );
    readmeContent = readmeContent.replace(/\{\{name\}\}/g, response.name);
    readmeContent = readmeContent.replace(
      /\{\{packageManager\}\}/g,
      packageManagerCommand
    );
    fs.writeFileSync(path.join(twistPath, "README.md"), readmeContent);
  } catch (error) {
    console.warn("Warning: Could not copy README template");
  }

  // Copy AGENTS.md from template
  const twistsTemplatePath = path.join(
    __dirname,
    "..",
    "templates",
    "AGENTS.template.md"
  );
  try {
    let twistsContent = fs.readFileSync(twistsTemplatePath, "utf-8");
    // Replace template variables
    twistsContent = twistsContent.replace(
      /\{\{packageManager\}\}/g,
      packageManagerCommand
    );
    fs.writeFileSync(path.join(twistPath, "AGENTS.md"), twistsContent);
  } catch (error) {
    console.warn("Warning: Could not copy AGENTS template");
  }

  // Copy CLAUDE.md from template
  const claudeTemplatePath = path.join(
    __dirname,
    "..",
    "templates",
    "CLAUDE.template.md"
  );
  try {
    const claudeContent = fs.readFileSync(claudeTemplatePath, "utf-8");
    fs.writeFileSync(path.join(twistPath, "CLAUDE.md"), claudeContent);
  } catch (error) {
    console.warn("Warning: Could not copy CLAUDE template");
  }

  // Create .gitignore
  const gitignore = `node_modules/
build/
.env
`;
  fs.writeFileSync(path.join(twistPath, ".gitignore"), gitignore);

  // Initialize git
  try {
    execSync("git init", { cwd: twistPath, stdio: "ignore" });
  } catch (error) {
    // Silently fail - not critical
  }

  const installCommand =
    packageManager === "yarn" ? "yarn" : `${packageManager} install`;

  // Install dependencies
  try {
    execSync(installCommand, { cwd: twistPath, stdio: "ignore" });
  } catch (error) {
    out.warning("Couldn't install dependencies", [
      `Run '${installCommand}' in ${twistDir}`,
    ]);
  }

  out.success(`${response.displayName} created`);

  out.nextSteps([
    `cd ${twistDir}`,
    `${packageManager === "npm" ? "npm run" : packageManager} lint`,
    `${packageManager === "npm" ? "npm run" : packageManager} deploy`,
  ]);
  out.blank();
}
