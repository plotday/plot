import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import * as out from "../utils/output";
import { getGlobalTokenPath } from "../utils/token";
import { bundleAgent } from "../utils/bundle";

interface DeployOptions {
  dir: string;
  spec?: string;
  id?: string;
  deployToken?: string;
  apiUrl: string;
  name?: string;
  description?: string;
  environment?: string;
}

interface PackageJson {
  name?: string;
  displayName?: string;
  description?: string;
  author?: string;
  license?: string;
  plotAgentId?: string;
  plotAgent?: {
    id?: string;
    tools?: string[];
  };
  env?: Record<string, any>;
}

export async function deployCommand(options: DeployOptions) {
  const agentPath = path.resolve(process.cwd(), options.dir);

  // Read spec file if provided
  let specContent: string | undefined;
  if (options.spec) {
    const specPath = path.resolve(process.cwd(), options.spec);
    if (!fs.existsSync(specPath)) {
      out.error(`Spec file not found: ${options.spec}`);
      process.exit(1);
    }
    try {
      specContent = fs.readFileSync(specPath, "utf-8");
    } catch (error) {
      out.error("Failed to read spec file", String(error));
      process.exit(1);
    }
  }

  // Verify we're in an agent directory by checking for package.json
  // Package.json is required when deploying source code, optional for spec
  const packageJsonPath = path.join(agentPath, "package.json");
  let packageJson: PackageJson | undefined;

  if (!options.spec) {
    // Source code deployment requires package.json
    if (!fs.existsSync(packageJsonPath)) {
      out.error(
        "package.json not found. Are you in an agent directory?",
        "Run this command from your agent's root directory, or use --spec to deploy from a spec file"
      );
      process.exit(1);
    }

    // Read and validate package.json
    try {
      const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
      packageJson = JSON.parse(packageJsonContent);
    } catch (error) {
      out.error("Failed to parse package.json", String(error));
      process.exit(1);
    }
  } else if (fs.existsSync(packageJsonPath)) {
    // Optional: read package.json for defaults when using spec
    try {
      const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
      packageJson = JSON.parse(packageJsonContent);
    } catch {
      // Ignore errors, package.json is optional for spec deployments
    }
  }

  // Extract agent metadata from package.json
  let agentId = packageJson?.plotAgentId;
  const agentName = packageJson?.displayName;
  const agentDescription = packageJson?.description;

  const environment = options.environment || "personal";

  // For spec deployments without package.json, require CLI options
  if (options.spec && !packageJson) {
    if (!options.id) {
      out.error(
        "Agent ID is required when deploying spec without package.json",
        "Provide --id flag"
      );
      process.exit(1);
    }
    if (!options.name) {
      out.error(
        "Agent name is required when deploying spec without package.json",
        "Provide --name flag"
      );
      process.exit(1);
    }
  }

  // Validate required fields for source code deployments
  if (!options.spec && !agentName) {
    out.error(
      "package.json is missing displayName",
      'Add "displayName": "Your Agent Name" to package.json'
    );
    process.exit(1);
  }

  // Validate Agent ID is present (from package.json or CLI)
  if (!agentId && !options.id) {
    out.error(
      "Agent ID missing",
      "Run 'plot agent create' to generate one, or provide --id flag"
    );
    process.exit(1);
  }

  // Resolve deployment ID, name, and description from options or package.json
  const deploymentId = options.id || agentId;
  const deploymentName = options.name || agentName;
  const deploymentDescription = options.description || agentDescription;

  // Load DEPLOY_TOKEN from multiple sources (CLI, env var, .env, global config)
  let deployToken = options.deployToken;
  const envPath = path.join(agentPath, ".env");

  if (!deployToken) {
    // Try to load from PLOT_DEPLOY_TOKEN environment variable
    deployToken = process.env.PLOT_DEPLOY_TOKEN;
  }

  if (!deployToken) {
    // Try to load from .env file
    if (fs.existsSync(envPath)) {
      const envConfig = dotenv.parse(fs.readFileSync(envPath));
      deployToken = envConfig.DEPLOY_TOKEN;
    }

    // Try to load from global token file
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

    // If still no token, prompt for it
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
        out.plain("\nDeployment cancelled.");
        process.exit(0);
      }

      deployToken = response.token;

      // Save token to .env file for future use
      const envContent = fs.existsSync(envPath)
        ? fs.readFileSync(envPath, "utf-8")
        : "";

      // Check if DEPLOY_TOKEN already exists in the file
      if (!envContent.includes("DEPLOY_TOKEN=")) {
        const newEnvContent =
          envContent +
          (envContent.endsWith("\n") || !envContent ? "" : "\n") +
          `DEPLOY_TOKEN=${deployToken}\n`;
        fs.writeFileSync(envPath, newEnvContent);
        out.success("Token saved to .env file");
      }
    }
  }

  // Prepare request body based on spec or source code
  let requestBody: {
    module?: string;
    spec?: string;
    name: string;
    description?: string;
    environment: string;
  };

  try {
    if (options.spec && specContent) {
      // Deploying from spec
      out.progress(`Deploying ${deploymentName} from spec...`);

      requestBody = {
        spec: specContent,
        name: deploymentName!,
        description: deploymentDescription,
        environment: environment,
      };
    } else {
      // Deploying from source code - build the agent
      out.progress(`Building ${deploymentName}...`);

      const result = await bundleAgent(agentPath, {
        minify: false,
        sourcemap: true,
      });

      const moduleContent = result.code;

      if (result.warnings.length > 0) {
        out.warning("Build completed with warnings");
        for (const warning of result.warnings.slice(0, 5)) {
          console.warn(`  ${warning}`);
        }
        if (result.warnings.length > 5) {
          console.warn(`  ... and ${result.warnings.length - 5} more warnings`);
        }
      }

      requestBody = {
        module: moduleContent,
        name: deploymentName!,
        description: deploymentDescription,
        environment: environment,
      };
    }

    // Validate all required deployment fields
    if (!deploymentName) {
      out.error(
        "Agent name is required",
        "Provide --name, or add 'displayName' to package.json"
      );
      process.exit(1);
    }

    // Description is only required for non-personal environments
    if (environment !== "personal" && !deploymentDescription) {
      out.error(
        "Agent description is required for non-personal environments",
        "Provide --description, or add 'description' to package.json"
      );
      process.exit(1);
    }

    // Use deploymentId for non-personal, or "personal" for personal environment
    const urlPath = deploymentId || "personal";

    try {
      const response = await fetch(`${options.apiUrl}/v1/agent/${urlPath}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${deployToken}`,
        },
        body: JSON.stringify(requestBody),
      });

      if (!response.ok) {
        const errorText = await response.text();
        out.error(
          `Upload failed: ${response.status} ${response.statusText}`,
          errorText
        );
        process.exit(1);
      }

      const result = (await response.json()) as any;

      // Show dependencies from API response
      const dependencies = result.dependencies;
      if (dependencies && dependencies.length > 0) {
        const deps = dependencies.map((depId: string) =>
          depId
            .split("-")
            .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
            .join(" ")
        );
        out.progress("Dependencies: " + deps.join(", "));
      }

      // Show success with relevant info
      out.success(`Deployed to ${environment} environment`);
    } catch (error) {
      out.error("Upload failed", String(error));
      process.exit(1);
    }
  } catch (error) {
    out.error("Build failed", String(error));
    process.exit(1);
  }
}
