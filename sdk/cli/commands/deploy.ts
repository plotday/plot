import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import { bundleAgent } from "../utils/bundle";
import * as out from "../utils/output";
import { handleSSEStream } from "../utils/sse";
import { getGlobalTokenPath } from "../utils/token";

interface DeployOptions {
  dir: string;
  id?: string;
  deployToken?: string;
  apiUrl: string;
  name?: string;
  description?: string;
  environment?: string;
  dryRun?: boolean;
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

  // Check for package.json
  const packageJsonPath = path.join(agentPath, "package.json");
  let packageJson: PackageJson | undefined;

  if (fs.existsSync(packageJsonPath)) {
    // Read and validate package.json
    try {
      const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
      packageJson = JSON.parse(packageJsonContent);
    } catch (error) {
      out.error("Failed to parse package.json", String(error));
      process.exit(1);
    }
  } else {
    // No package.json - check for plot-agent.md as fallback
    const specPath = path.join(agentPath, "plot-agent.md");
    if (fs.existsSync(specPath)) {
      out.info("No package.json found, but plot-agent.md exists", [
        "Generating agent from spec first...",
      ]);

      // Import and run generate command
      const { generateCommand } = await import("./generate");
      await generateCommand({
        dir: options.dir,
        id: options.id,
        deployToken: options.deployToken,
        apiUrl: options.apiUrl,
      });

      // Re-read the generated package.json
      try {
        const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
        packageJson = JSON.parse(packageJsonContent);
      } catch (error) {
        out.error("Failed to read generated package.json", String(error));
        process.exit(1);
      }

      out.blank();
      out.progress("Continuing with deployment...");
    } else {
      out.error(
        "Neither package.json nor plot-agent.md found",
        "Run 'plot agent create' to create a new agent, or create a plot-agent.md spec file"
      );
      process.exit(1);
    }
  }

  // Extract agent metadata from package.json
  let agentId = packageJson?.plotAgentId;
  const agentName = packageJson?.displayName;
  const agentDescription = packageJson?.description;

  const environment = options.environment || "personal";

  // Validate required fields
  if (!agentName) {
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

  // Build the agent
  let requestBody: {
    module: string;
    name: string;
    description?: string;
    environment: string;
    dryRun?: boolean;
  };

  try {
    out.progress(
      options.dryRun
        ? `Validating ${deploymentName}...`
        : `Building ${deploymentName}...`
    );

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
      dryRun: options.dryRun,
    };

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
          Accept: "text/event-stream",
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

      // Handle SSE stream with progress updates
      const result = (await handleSSEStream(response, {
        onProgress: (message) => {
          out.progress(message);
        },
      })) as any;

      if (!result) {
        out.error("Upload failed");
        process.exit(1);
      }

      // Handle dryRun response
      if (options.dryRun) {
        if (result.errors && result.errors.length > 0) {
          out.error("Validation failed");
          for (const error of result.errors) {
            console.error(`  ${error}`);
          }
          process.exit(1);
        } else {
          out.success("Validation passed - agent is ready to deploy");
          out.info("Run without --dry-run to deploy", [`plot agent deploy`]);
        }
        return;
      }

      // Show permissions from API response
      const permissions = result.permissions;
      if (permissions && Object.keys(permissions).length > 0) {
        out.info("Permissions:", []);
        for (const [toolName, toolPermissions] of Object.entries(permissions)) {
          console.log(`  ${toolName}:`);

          // Display each permission property
          if (toolPermissions && typeof toolPermissions === "object") {
            for (const [key, value] of Object.entries(toolPermissions)) {
              if (Array.isArray(value)) {
                if (value.length > 0) {
                  console.log(`    ${key}:`);
                  for (const item of value) {
                    console.log(`      - ${item}`);
                  }
                } else {
                  console.log(`    ${key}: []`);
                }
              } else {
                console.log(`    ${key}: ${JSON.stringify(value)}`);
              }
            }
          }
        }
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
