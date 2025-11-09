---
title: CLI Reference
group: Guides
---

# CLI Reference

Complete reference for the Plot CLI (`plot` command).

## Table of Contents

- [Installation](#installation)
- [Authentication](#authentication)
- [twist Commands](#twist-commands)
- [Priority Commands](#priority-commands)
- [Global Options](#global-options)

---

## Installation

The Plot CLI is included with the Builder:

```bash
# Run directly with npx
npx @plotday/twister [command]

# Or install globally
npm install -g @plotday/twister
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
3. Enable deploying and managing twists

**Token Storage**: The token is stored in `~/.plot/config.json`

---

## twist Commands

### plot create

Scaffold a new twist project with TypeScript.

```bash
plot create [options]
```

**Options:**

- `--name <name>` - Package name (kebab-case)
- `--display-name <name>` - Human-readable display name
- `--dir <directory>` - Output directory (default: current directory)

**Example:**

```bash
plot create --name my-calendar-twist --display-name "My Calendar twist"
```

**Creates:**

```
my-calendar-twist/
├── src/
│   └── index.ts
├── package.json
├── tsconfig.json
└── plot-twist.json
```

---

### plot generate

Generate TypeScript code from a natural language `plot-twist.md` specification.

```bash
plot generate [options]
```

**Options:**

- `--input <path>` - Path to plot-twist.md (default: `./plot-twist.md`)
- `--output <directory>` - Output directory (default: `./src`)
- `--overwrite` - Overwrite existing files

**Example:**

```bash
plot generate --input ./my-spec.md --output ./src
```

---

### plot lint

Check twist code for errors without deploying.

```bash
plot lint [options]
```

**Options:**

- `--dir <directory>` - twist directory (default: current directory)

**Example:**

```bash
plot lint --dir ./my-twist
```

---

### plot deploy

Deploy an twist to Plot.

```bash
plot deploy [options]
```

**Options:**

- `--twist-id <id>` - Update existing twist (creates new if not specified)
- `--name <name>` - twist name
- `--description <description>` - twist description
- `--source <path>` - Source directory (default: `./src`)
- `--env <environment>` - Environment (default: `production`)
- `--dry-run` - Validate without deploying

**Behavior:**

- If `plot-twist.md` exists: Generates code and deploys in one step
- Otherwise: Deploys compiled TypeScript from `src/`

**Example:**

```bash
# Deploy new twist
plot deploy

# Update existing twist
plot deploy --twist-id ag_1234567890

# Dry run
plot deploy --dry-run
```

---

### plot logs

Stream real-time logs from an twist.

```bash
plot logs [twist-id] [options]
```

**Options:**

- `--id <twistId>` - twist ID
- `--dir <directory>` - twist directory (default: current directory)
- `--environment <env>` - twist environment (personal, private, review) (default: personal)
- `--deploy-token <token>` - Authentication token

**Example:**

```bash
# Stream logs for an twist
plot logs ag_1234567890

# Stream logs using twist in current directory
plot logs --dir ./my-twist
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
    "twistSourceDir": "./dist"
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

### Create and Deploy a New twist

```bash
# 1. Create project
plot create --name my-twist

# 2. Navigate to directory
cd my-twist

# 3. Implement twist
# Edit src/index.ts

# 4. Login (if not already authenticated)
plot login

# 5. Deploy
npm run deploy
```

### Update an Existing twist

```bash
# 1. Make changes to src/index.ts

# 2. Build
npm run build

# 3. Deploy update
plot deploy --twist-id ag_1234567890
```

### No-Code twist Deployment

```bash
# 1. Create plot-twist.md
# Describe your twist in plain English

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

- **[Getting Started](GETTING_STARTED.md)** - Learn how to build twists
- **[Core Concepts](CORE_CONCEPTS.md)** - Understand the twist architecture
- **[Built-in Tools](TOOLS_GUIDE.md)** - Explore available tools
