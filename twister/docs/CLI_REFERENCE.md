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

The Plot CLI is included with the Twist Creator package:

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

**Token Storage**: The token is saved per API host at `~/.config/plot/credentials/<api-host>/token` (e.g. `~/.config/plot/credentials/api.plot.day/token`). On Windows it is stored under `%APPDATA%\plot\credentials\`.

---

## twist Commands

### plot create

Scaffold a new twist project with TypeScript.

```bash
plot create [options]
```

**Options:**

- `-n, --name <name>` - Package name (kebab-case)
- `--display-name <name>` - Human-readable display name
- `-d, --dir <directory>` - Output directory (default: a new directory named after the package)
- `--connector` - Create a connector instead of a twist

If `--name` and `--display-name` are not both provided, the command prompts for them interactively.

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
├── README.md
├── AGENTS.md
├── CLAUDE.md
└── .gitignore
```

It also initializes a git repository and installs dependencies with the detected package manager.

---

### plot generate

Generate TypeScript code from a natural language `plot-twist.md` specification.

```bash
plot generate [options]
```

**Options:**

- `-d, --dir <directory>` - Twist directory to generate in (default: current directory)
- `--spec <file>` - Spec file to generate from (default: `plot-twist.md` inside the twist directory)
- `--id <twistId>` - Twist ID (reads `plotTwistId` from `package.json` if present, otherwise generates a new UUID)
- `--deploy-token <token>` - Authentication token (falls back to the `PLOT_DEPLOY_TOKEN` env var, `DEPLOY_TOKEN` in `.env`, or the token saved by `plot login`)

If existing files would be overwritten, the command prompts before proceeding. On success it writes `package.json`, `tsconfig.json`, `README.md`, `AGENTS.md`, `CLAUDE.md`, and the generated source files into `src/`, then runs `pnpm install` (or the detected package manager).

**Example:**

```bash
# Generate from ./my-twist/plot-twist.md into ./my-twist
plot generate --dir ./my-twist

# Or point at a spec file elsewhere
plot generate --dir ./my-twist --spec ./specs/my-twist.md
```

---

### plot lint

Check twist code for errors without deploying.

```bash
plot lint [options]
```

**Options:**

- `-d, --dir <directory>` - twist directory (default: current directory)

**Example:**

```bash
plot lint --dir ./my-twist
```

---

### plot build

Bundle the twist without deploying.

```bash
plot build [options]
```

**Options:**

- `-d, --dir <directory>` - twist directory (default: current directory)

Writes the bundle to `build/index.js` and prints its size. Useful for verifying the build locally or in CI pipelines that separate build and deploy steps.

**Example:**

```bash
plot build --dir ./my-twist
```

---

### plot deploy

Deploy a twist to Plot.

```bash
plot deploy [options]
```

**Options:**

- `-d, --dir <directory>` - twist directory (default: current directory)
- `--id <twistId>` - Twist ID (default: `plotTwistId` from `package.json`)
- `--name <name>` - twist name (default: `displayName` from `package.json`)
- `--description <description>` - twist description (default: `description` from `package.json`; required for non-personal environments)
- `--deploy-token <token>` - Authentication token (falls back to the `PLOT_DEPLOY_TOKEN` env var, `DEPLOY_TOKEN` in `.env`, or the token saved by `plot login`)
- `-e, --environment <env>` - Deployment environment: `personal`, `private`, `review`, or `public` (default: `personal`)
- `--dry-run` - Validate without deploying

**Behavior:**

- Type-checks the code (`tsc --noEmit`), bundles it, and uploads it to Plot
- If there is no `package.json` but a `plot-twist.md` spec exists: generates the twist from the spec first, then deploys
- Non-personal environments require a description and a publisher (resolved from `publisher` in `package.json`, or selected/created interactively)

**Example:**

```bash
# Deploy (twist ID is read from package.json)
plot deploy

# Deploy to a shared environment
plot deploy --environment private

# Dry run
plot deploy --dry-run
```

---

### plot logs

Stream real-time logs from a twist.

```bash
plot logs [twist-id] [options]
```

**Options:**

- `--id <twistId>` - twist ID (when omitted, read from `plotTwistId` in `package.json`)
- `-d, --dir <directory>` - twist directory (default: current directory)
- `-e, --environment <env>` - twist environment: `personal`, `private`, `review`, or `public` (default: `personal`)
- `--deploy-token <token>` - Authentication token

**Example:**

```bash
# Stream logs for a twist by ID
plot logs 123e4567-e89b-42d3-a456-426614174000

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
ID                                     Parent ID                              Title
------------------------------------------------------------------------------------
6e1f0336-...                           (root)                                 Work
9b2c4a18-...                           6e1f0336-...                           Project A
0a7d92e4-...                           (root)                                 Personal

Total: 3 priorities
```

---

### plot priority create

Create a new priority.

```bash
plot priority create [options]
```

**Options:**

- `--name <name>` - Priority name (prompted for if omitted)
- `--parent-id <id>` - Parent priority ID, a UUID (prompted for if omitted; leave empty for a root priority)

**Example:**

```bash
# Create top-level priority
plot priority create --name "Work"

# Create nested priority
plot priority create --name "Project A" --parent-id 6e1f0336-58d4-4f5a-9c2b-7a1d3e8f0b42
```

---

## Global Options

These options are available for all commands:

- `-h, --help` - Show help for command
- `-V, --version` - Show CLI version

**Example:**

```bash
plot --version
plot deploy --help
```

---

## Stored Credentials

The CLI does not use a configuration file. Credentials are stored in two places:

- **Login token**: `plot login` saves your token per API host at `~/.config/plot/credentials/<api-host>/token` (Windows: `%APPDATA%\plot\credentials\<api-host>\token`)
- **Deploy token**: a `DEPLOY_TOKEN` entry in the twist directory's `.env` file (written automatically if you enter a token when prompted)

When a command needs a token, it resolves one in this order:

1. `--deploy-token` flag
2. `PLOT_DEPLOY_TOKEN` environment variable
3. `DEPLOY_TOKEN` in the twist directory's `.env` file
4. The saved login token for the current API host

---

## Environment Variables

Configure the CLI using environment variables:

- `PLOT_DEPLOY_TOKEN` - API authentication token
- `PLOT_API_URL` - API endpoint (default: `https://api.plot.day`)
- `PLOT_SITE_URL` - Site endpoint used by `plot login` (default: `https://plot.day`)

**Example:**

```bash
export PLOT_DEPLOY_TOKEN=your-token
plot deploy
```

---

## Common Workflows

### Create and Deploy a New twist

```bash
# 1. Create project
plot create --name my-twist --display-name "My twist"

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

# 2. Check for errors
npm run lint

# 3. Deploy update (twist ID is read from plotTwistId in package.json)
plot deploy
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
rm ~/.config/plot/credentials/api.plot.day/token

# Login again
plot login
```

### Build Errors

```bash
# Check for TypeScript errors
plot lint

# Or check that the bundle builds
plot build
```

### Deployment Failures

```bash
# Try dry run first
plot deploy --dry-run

# After deploying, stream logs to debug runtime issues
plot logs
```

---

## Next Steps

- **[Getting Started](GETTING_STARTED.md)** - Learn how to build twists
- **[Core Concepts](CORE_CONCEPTS.md)** - Understand the twist architecture
- **[Built-in Tools](TOOLS_GUIDE.md)** - Explore available tools
