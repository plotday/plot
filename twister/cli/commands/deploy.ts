import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import prompts from "prompts";

import { bundleTwist } from "../utils/bundle";
import { handleNetworkError } from "../utils/network-error";
import * as out from "../utils/output";
import { handleSSEStream } from "../utils/sse";
import { getGlobalTokenPath } from "../utils/token";
import { checkAndReportWorkspaceDependencies } from "../utils/typecheck";

// Publisher types for API interaction
interface Publisher {
  id: number;
  name: string;
  email: string | null;
  url: string | null;
}

interface NewPublisher {
  name: string;
  url?: string | null;
}

// Twist info response from GET /v1/twist/:id
interface TwistInfo {
  id: number;
  twist_package_id: string;
  priority_id: string | null;
  publisher: Publisher | null;
  created_at: string;
  updated_at: string;
}

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
  plotTwistId?: string;
  plotTwist?: {
    id?: string;
    tools?: string[];
  };
  env?: Record<string, any>;
}

async function createNewPublisher(
  apiUrl: string,
  deployToken: string
): Promise<number> {
  // Try to get user's name for default
  let defaultName = "";
  try {
    const userResponse = await fetch(`${apiUrl}/v1/twist/user`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${deployToken}`,
      },
    });
    if (userResponse.ok) {
      const userData = (await userResponse.json()) as {
        name: string;
        email: string;
      };
      defaultName = userData.name;
    } else if (userResponse.status === 401) {
      out.error(
        "Authentication failed",
        "Your login token is invalid or has expired. Please run 'plot login' to authenticate."
      );
      process.exit(1);
    }
  } catch (error) {
    // Ignore error, just won't have default
  }

  // Prompt for publisher details
  const response = await prompts([
    {
      type: "text",
      name: "name",
      message: "Publisher name:",
      initial: defaultName,
      validate: (value: string) => value.length > 0 || "Name is required",
    },
    {
      type: "text",
      name: "url",
      message: "Publisher URL (optional):",
      validate: (value: string) => {
        if (!value) return true; // Optional
        try {
          new URL(value);
          return true;
        } catch {
          return "Please enter a valid URL";
        }
      },
    },
  ]);

  if (response.name === undefined) {
    out.plain("\nDeployment cancelled.");
    process.exit(0);
  }

  // Use default name if user pressed Enter with empty input
  const publisherName = response.name || defaultName;

  if (!publisherName) {
    out.error("Publisher name is required");
    process.exit(1);
  }

  // Create publisher via API
  try {
    out.progress(`Creating publisher "${publisherName}"...`);

    const createResponse = await fetch(`${apiUrl}/v1/twist/publishers`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${deployToken}`,
      },
      body: JSON.stringify({
        name: publisherName,
        url: response.url || null,
      } as NewPublisher),
    });

    if (!createResponse.ok) {
      if (createResponse.status === 401) {
        out.error(
          "Authentication failed",
          "Your login token is invalid or has expired. Please run 'plot login' to authenticate."
        );
        process.exit(1);
      }
      const errorText = await createResponse.text();
      out.error("Failed to create publisher", errorText);
      process.exit(1);
    }

    const publisher = (await createResponse.json()) as Publisher;
    out.success(`Publisher "${publisher.name}" created`);
    return publisher.id;
  } catch (error) {
    const errorInfo = handleNetworkError(error);
    out.error("Failed to create publisher", errorInfo.message);
    process.exit(1);
  }
}

export async function deployCommand(options: DeployOptions) {
  const twistPath = path.resolve(process.cwd(), options.dir);

  // Check for package.json
  const packageJsonPath = path.join(twistPath, "package.json");
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
    // No package.json - check for plot-twist.md as fallback
    const specPath = path.join(twistPath, "plot-twist.md");
    if (fs.existsSync(specPath)) {
      out.info("No package.json found, but plot-twist.md exists", [
        "Generating twist from spec first...",
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
        "Neither package.json nor plot-twist.md found",
        "Run 'plot create' to create a new twist, or create a plot-twist.md spec file"
      );
      process.exit(1);
    }
  }

  // Extract twist metadata from package.json
  let twistId = packageJson?.plotTwistId;
  const twistName = packageJson?.displayName;
  const twistDescription = packageJson?.description;

  const environment = options.environment || "personal";

  // Validate required fields
  if (!twistName) {
    out.error(
      "package.json is missing displayName",
      'Add "displayName": "Your Twist Name" to package.json'
    );
    process.exit(1);
  }

  // Validate Twist ID is present (from package.json or CLI)
  if (!twistId && !options.id) {
    out.error(
      "Twist ID missing",
      "Run 'plot create' to generate one, or provide --id flag"
    );
    process.exit(1);
  }

  // Resolve deployment ID, name, and description from options or package.json
  const deploymentId = options.id || twistId;
  const deploymentName = options.name || twistName;
  const deploymentDescription = options.description || twistDescription;

  // Load DEPLOY_TOKEN from multiple sources (CLI, env var, .env, global config)
  let deployToken = options.deployToken;
  const envPath = path.join(twistPath, ".env");

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

  // Handle publisher selection for non-personal deployments
  let publisherId: number | undefined;

  if (environment !== "personal") {
    // First, check if this twist already has a publisher set up
    let needsPublisher = true;
    const urlPath = deploymentId || "personal";

    try {
      const twistInfoResponse = await fetch(
        `${options.apiUrl}/v1/twist/${urlPath}`,
        {
          method: "GET",
          headers: {
            Authorization: `Bearer ${deployToken}`,
          },
        }
      );

      if (twistInfoResponse.ok) {
        const twistInfo = (await twistInfoResponse.json()) as TwistInfo;
        if (twistInfo.publisher) {
          // Publisher already set, no need to prompt
          needsPublisher = false;
          publisherId = twistInfo.publisher.id;
        }
      } else if (twistInfoResponse.status === 401) {
        // Authentication failure - exit with helpful message
        out.error(
          "Authentication failed",
          "Your login token is invalid or has expired. Please run 'plot login' to authenticate."
        );
        process.exit(1);
      } else if (twistInfoResponse.status !== 404) {
        // Log non-404 errors, but continue with publisher setup
        const errorText = await twistInfoResponse.text();
        out.warning("Could not check existing twist status", [errorText]);
      }
      // 404 means twist not published yet, which is expected for first deployment
    } catch (error) {
      // Network errors, continue with publisher setup
      const errorInfo = handleNetworkError(error);
      out.warning("Could not check existing twist status", [
        errorInfo.message,
      ]);
    }

    // Only prompt for publisher if needed
    if (needsPublisher) {
      let publishers: Publisher[] = [];
      let fetchSucceeded = false;

      try {
        // Fetch accessible publishers
      const publishersResponse = await fetch(
        `${options.apiUrl}/v1/twist/publishers`,
        {
          method: "GET",
          headers: {
            Authorization: `Bearer ${deployToken}`,
          },
        }
      );

      if (!publishersResponse.ok) {
        if (publishersResponse.status === 401) {
          // Authentication failure - exit with helpful message
          out.error(
            "Authentication failed",
            "Your login token is invalid or has expired. Please run 'plot login' to authenticate."
          );
          process.exit(1);
        }
        const errorText = await publishersResponse.text();
        out.warning("Failed to fetch publishers", [errorText]);
      } else {
        publishers = (await publishersResponse.json()) as Publisher[];
        fetchSucceeded = true;
      }
    } catch (error) {
      const errorInfo = handleNetworkError(error);
      out.warning("Failed to fetch publishers", [errorInfo.message]);
    }

    // Always prompt for publisher, even if fetch failed
    if (fetchSucceeded && publishers.length > 0) {
      // Show selection UI with existing publishers + "New publisher" option
      const choices = [
        ...publishers.map((p) => ({
          title: p.name,
          description: p.url || undefined,
          value: p.id,
        })),
        {
          title: "New publisher",
          description: "Create a new publisher",
          value: -1,
        },
      ];

      const response = await prompts({
        type: "select",
        name: "publisherId",
        message: "Select a publisher for this twist:",
        choices,
      });

      if (response.publisherId === undefined) {
        out.plain("\nDeployment cancelled.");
        process.exit(0);
      }

      if (response.publisherId === -1) {
        // Create new publisher
        publisherId = await createNewPublisher(options.apiUrl, deployToken!);
      } else {
        publisherId = response.publisherId;
      }
    } else {
      // No existing publishers or fetch failed - create new one
      if (!fetchSucceeded) {
        out.info("Could not fetch existing publishers", [
          "You can create a new publisher to continue",
        ]);
      }
      publisherId = await createNewPublisher(options.apiUrl, deployToken!);
      }
    }
  }

  // Check workspace dependencies first
  checkAndReportWorkspaceDependencies(twistPath);

  // Build the twist
  let requestBody: {
    module: string;
    sourcemap?: string;
    name: string;
    description?: string;
    environment: string;
    publisherId?: number;
    dryRun?: boolean;
  };

  try {
    out.progress(
      options.dryRun
        ? `Validating ${deploymentName}...`
        : `Building ${deploymentName}...`
    );

    const result = await bundleTwist(twistPath, {
      minify: false,
      sourcemap: true,
    });

    const moduleContent = result.code;
    const sourcemapContent = result.sourcemap;

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
      sourcemap: sourcemapContent,
      name: deploymentName!,
      description: deploymentDescription,
      environment: environment,
      publisherId,
      dryRun: options.dryRun,
    };

    // Validate all required deployment fields
    if (!deploymentName) {
      out.error(
        "Twist name is required",
        "Provide --name, or add 'displayName' to package.json"
      );
      process.exit(1);
    }

    // Description is only required for non-personal environments
    if (environment !== "personal" && !deploymentDescription) {
      out.error(
        "Twist description is required for non-personal environments",
        "Provide --description, or add 'description' to package.json"
      );
      process.exit(1);
    }

    // Use deploymentId for non-personal, or "personal" for personal environment
    const urlPath = deploymentId || "personal";

    try {
      const response = await fetch(`${options.apiUrl}/v1/twist/${urlPath}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "text/event-stream",
          Authorization: `Bearer ${deployToken}`,
        },
        body: JSON.stringify(requestBody),
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
        out.error("Upload failed", errorText);
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
          out.success("Validation passed - twist is ready to deploy");
          out.info("Run without --dry-run to deploy", [`plot deploy`]);
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
      const errorInfo = handleNetworkError(error);
      out.error("Upload failed", errorInfo.message);
      if (errorInfo.details) {
        console.error(out.colors.dim(errorInfo.details));
      }
      process.exit(1);
    }
  } catch (error) {
    out.error("Build failed", String(error));
    process.exit(1);
  }
}
