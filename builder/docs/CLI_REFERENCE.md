---
title: CLI Reference
group: Guides
---

# CLI Reference

Complete reference for the Plot CLI (`plot` command).

## Table of Contents

- [Installation](#installation)
- [Authentication](#authentication)
- [Agent Commands](#agent-commands)
- [Priority Commands](#priority-commands)
- [Global Options](#global-options)

---

## Installation

The Plot CLI is included with the Builder:

```bash
# Run directly with npx
npx @plotday/agent [command]

# Or install globally
npm install -g @plotday/agent
plot [command]
```

---

## Authentication

### plot login

Authenticate with Plot to generate an API token.

```bash
plot login
```

This will:

1. Open your browser to the Plot authentication page
2. After authentication, save your API token locally
3. Enable deploying and managing agents

**Token Storage**: The token is stored in `~/.plot/config.json`

---

## Agent Commands

### plot create

Scaffold a new agent project with TypeScript.

```bash
plot create [options]
```

**Options:**

- `--name <name>` - Package name (kebab-case)
- `--display-name <name>` - Human-readable display name
- `--dir <directory>` - Output directory (default: current directory)

**Example:**

```bash
plot create --name my-calendar-agent --display-name "My Calendar Agent"
```

**Creates:**

```
my-calendar-agent/
├── src/
│   └── index.ts
├── package.json
├── tsconfig.json
└── plot-agent.json
```

---

### plot generate

Generate TypeScript code from a natural language `plot-agent.md` specification.

```bash
plot generate [options]
```

**Options:**

- `--input <path>` - Path to plot-agent.md (default: `./plot-agent.md`)
- `--output <directory>` - Output directory (default: `./src`)
- `--overwrite` - Overwrite existing files

**Example:**

```bash
plot generate --input ./my-spec.md --output ./src
```

---

### plot lint

Check agent code for errors without deploying.

```bash
plot lint [options]
```

**Options:**

- `--dir <directory>` - Agent directory (default: current directory)

**Example:**

```bash
plot lint --dir ./my-agent
```

---

### plot deploy

Deploy an agent to Plot.

```bash
plot deploy [options]
```

**Options:**

- `--agent-id <id>` - Update existing agent (creates new if not specified)
- `--name <name>` - Agent name
- `--description <description>` - Agent description
- `--source <path>` - Source directory (default: `./src`)
- `--env <environment>` - Environment (default: `production`)
- `--dry-run` - Validate without deploying

**Behavior:**

- If `plot-agent.md` exists: Generates code and deploys in one step
- Otherwise: Deploys compiled TypeScript from `src/`

**Example:**

```bash
# Deploy new agent
plot deploy

# Update existing agent
plot deploy --agent-id ag_1234567890

# Dry run
plot deploy --dry-run
```

---

### plot logs

Stream real-time logs from an agent.

```bash
plot logs [agent-id] [options]
```

**Options:**

- `--id <agentId>` - Agent ID
- `--dir <directory>` - Agent directory (default: current directory)
- `--environment <env>` - Agent environment (personal, private, review) (default: personal)
- `--deploy-token <token>` - Authentication token

**Example:**

```bash
# Stream logs for an agent
plot logs ag_1234567890

# Stream logs using agent in current directory
plot logs --dir ./my-agent
```

---

## Priority Commands

### plot priority list

List all priorities for the authenticated user.

```bash
plot priority list
```

**Output:**

```
pr_0987654321  Work
  pr_1111111111  Project A
  pr_2222222222  Project B
pr_3333333333  Personal
```

---

### plot priority create

Create a new priority.

```bash
plot priority create [options]
```

**Options:**

- `--name <name>` - Priority name (required)
- `--parent-id <id>` - Parent priority ID (optional)

**Example:**

```bash
# Create top-level priority
plot priority create --name "Work"

# Create nested priority
plot priority create --name "Project A" --parent-id pr_0987654321
```

---

## Global Options

These options are available for all commands:

- `--help`, `-h` - Show help for command
- `--version`, `-v` - Show CLI version
- `--verbose` - Enable verbose logging
- `--config <path>` - Use custom config file (default: `~/.plot/config.json`)

**Example:**

```bash
plot deploy --verbose
plot --version
```

---

## Configuration File

The CLI stores configuration in `~/.plot/config.json`:

```json
{
  "auth": {
    "token": "your-api-token",
    "userId": "user_1234567890"
  },
  "defaults": {
    "environment": "production"
  }
}
```

### Customizing Defaults

Edit the config file to set default options:

```json
{
  "defaults": {
    "environment": "staging",
    "agentSourceDir": "./dist"
  }
}
```

---

## Environment Variables

Configure the CLI using environment variables:

- `PLOT_API_TOKEN` - API authentication token
- `PLOT_API_URL` - API endpoint (default: `https://api.plot.day`)
- `PLOT_CONFIG_PATH` - Custom config file path

**Example:**

```bash
export PLOT_API_TOKEN=your-token
plot deploy
```

---

## Common Workflows

### Create and Deploy a New Agent

```bash
# 1. Create project
plot create --name my-agent

# 2. Navigate to directory
cd my-agent

# 3. Implement agent
# Edit src/index.ts

# 4. Login (if not already authenticated)
plot login

# 5. Deploy
npm run deploy
```

### Update an Existing Agent

```bash
# 1. Make changes to src/index.ts

# 2. Build
npm run build

# 3. Deploy update
plot deploy --agent-id ag_1234567890
```

### No-Code Agent Deployment

```bash
# 1. Create plot-agent.md
# Describe your agent in plain English

# 2. Login
plot login

# 3. Deploy directly from spec
plot deploy
```

---

## Troubleshooting

### Authentication Issues

```bash
# Clear saved token
rm ~/.plot/config.json

# Login again
plot login
```

### Build Errors

```bash
# Check for TypeScript errors
npm run build

# Or use lint command
plot lint
```

### Deployment Failures

```bash
# Try dry run first
plot deploy --dry-run

# Enable verbose logging
plot deploy --verbose
```

---

## Next Steps

- **[Getting Started](GETTING_STARTED.md)** - Learn how to build agents
- **[Core Concepts](CORE_CONCEPTS.md)** - Understand the agent architecture
- **[Built-in Tools](TOOLS_GUIDE.md)** - Explore available tools
