#!/usr/bin/env node
import { Command, Option } from "commander";
import { readFileSync } from "fs";
import { join } from "path";

import { agentLogsCommand } from "./commands/agent-logs";
import { buildCommand } from "./commands/build";
import { createCommand } from "./commands/create";
import { deployCommand } from "./commands/deploy";
import { generateCommand } from "./commands/generate";
import { lintCommand } from "./commands/lint";
import { loginCommand } from "./commands/login";
import { priorityCreateCommand } from "./commands/priority-create";
import { priorityListCommand } from "./commands/priority-list";
import { cliHeader } from "./utils/output";

// Get the version from package.json
const packageJsonPath = join(__dirname, "..", "package.json");
const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf-8"));
const version = packageJson.version;

// Display CLI header
cliHeader(version);

const program = new Command();

program
  .name("plot")
  .description("CLI tool for building and deploying Plot agents")
  .version(version)
  .addOption(
    new Option("--api-url <url>", "API endpoint URL")
      .default(process.env.PLOT_API_URL || "https://api.plot.day")
      .hideHelp()
  )
  .addOption(
    new Option("--site-url <url>", "Site endpoint URL")
      .default(process.env.PLOT_SITE_URL || "https://plot.day")
      .hideHelp()
  );

// Top-level login command
program
  .command("login")
  .description("Authenticate with Plot to generate an API token")
  .action(function (this: Command) {
    const opts = this.optsWithGlobals() as { siteUrl: string; apiUrl: string };
    return loginCommand(opts);
  });

// Top-level create command
program
  .command("create")
  .description("Create a new Plot agent")
  .option("-d, --dir <directory>", "Directory to create the agent in")
  .option("-n, --name <name>", "Package name (kebab-case)")
  .option("--display-name <displayName>", "Display name for the agent")
  .action(createCommand);

// Top-level lint command
program
  .command("lint")
  .description("Check for build or lint errors")
  .option("-d, --dir <directory>", "Agent directory to lint", process.cwd())
  .action(lintCommand);

// Top-level build command
program
  .command("build")
  .description("Bundle the agent without deploying")
  .option("-d, --dir <directory>", "Agent directory to build", process.cwd())
  .action(buildCommand);

// Top-level generate command
program
  .command("generate")
  .description("Generate agent code from a spec file")
  .option("-d, --dir <directory>", "Agent directory to generate in", process.cwd())
  .option("--spec <file>", "Spec file to generate from (defaults to plot-agent.md)")
  .option("--id <agentId>", "Agent ID")
  .option("--deploy-token <token>", "Authentication token")
  .action(function (this: Command) {
    const opts = this.optsWithGlobals() as {
      dir: string;
      spec?: string;
      id?: string;
      deployToken?: string;
      apiUrl: string;
    };
    return generateCommand(opts);
  });

// Top-level deploy command
program
  .command("deploy")
  .description("Bundle and deploy the agent")
  .option("-d, --dir <directory>", "Agent directory to deploy", process.cwd())
  .option("--id <agentId>", "Agent ID for deployment")
  .option("--deploy-token <token>", "Authentication token for deployment")
  .option("--name <name>", "Agent name")
  .option("--description <description>", "Agent description")
  .option("--dry-run", "Validate without deploying")
  .option(
    "-e, --environment <env>",
    "Deployment environment (personal, private, review)",
    "personal"
  )
  .action(function (this: Command) {
    const opts = this.optsWithGlobals() as {
      dir: string;
      id?: string;
      deployToken?: string;
      apiUrl: string;
      name?: string;
      description?: string;
      environment?: string;
      dryRun?: boolean;
    };
    return deployCommand(opts);
  });

// Top-level logs command
program
  .command("logs [agent-id]")
  .description("Stream real-time logs from an agent")
  .option("-d, --dir <directory>", "Agent directory", process.cwd())
  .option("--id <agentId>", "Agent ID")
  .option(
    "-e, --environment <env>",
    "Agent environment (personal, private, review)",
    "personal"
  )
  .option("--deploy-token <token>", "Authentication token")
  .action(function (this: Command, agentId?: string) {
    const opts = this.optsWithGlobals() as {
      dir?: string;
      id?: string;
      environment?: string;
      deployToken?: string;
      apiUrl: string;
    };
    return agentLogsCommand({
      agentId,
      id: opts.id,
      dir: opts.dir,
      environment: opts.environment,
      deployToken: opts.deployToken,
      apiUrl: opts.apiUrl,
    });
  });

// Priority subcommand group
const priority = program
  .command("priority")
  .description("Manage Plot priorities");

priority
  .command("create")
  .description("Create a new priority")
  .option("--name <name>", "Priority name")
  .option("--parent-id <parentId>", "Parent priority ID")
  .action(function (this: Command) {
    const opts = this.optsWithGlobals() as {
      name?: string;
      parentId?: string;
      apiUrl: string;
    };
    return priorityCreateCommand(opts);
  });

priority
  .command("list")
  .description("List all your priorities")
  .action(function (this: Command) {
    const opts = this.optsWithGlobals() as {
      apiUrl: string;
    };
    return priorityListCommand(opts);
  });

program.parse();
