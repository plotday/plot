---
title: Getting Started
group: Guides
---

# Getting Started with Plot Agents

This guide will walk you through creating your first Plot agent. There are two ways to build agents: with natural language (no code) or with TypeScript code for maximum flexibility.

## Choose Your Path

- **[No-Code Agents](#no-code-agents)** - Perfect for non-developers or rapid prototyping
- **[Developer Agents](#developer-agents)** - Full control with TypeScript

---

## No-Code Agents

Create agents using natural language descriptions - no programming required!

### Step 1: Create a plot-agent.md File

Create a file named `plot-agent.md` in your project directory and describe what you want your agent to do:

```markdown
# My Calendar Agent

I want an agent that:

- Syncs my Google Calendar events into Plot as activities
- Creates tasks for upcoming meetings
- Sends me a reminder 10 minutes before each meeting
- Updates activity status when meetings are completed
```

**Be specific about:**

- **Data sources** - Which services to connect (Google Calendar, GitHub, Slack, etc.)
- **Actions** - What the agent should do (create tasks, send notifications, update status)
- **Triggers** - When actions should happen (on new events, on schedule, when activities change)

### Step 2: Deploy Your Agent

You'll need a [Plot account](https://plot.day) to deploy agents.

```bash
# Login to Plot
npx @plotday/agent login

# Deploy directly from your spec
npx @plotday/agent deploy
```

That's it! Your agent is now live in Plot.

### Optional: Generate Code First

If you want to review or customize the generated code before deploying:

```bash
# Generate TypeScript code from your spec
npx @plotday/agent generate

# Review and edit the generated src/index.ts
# Then deploy
npx @plotday/agent deploy
```

The `generate` command creates a complete TypeScript agent that you can modify and extend.

---

## Developer Agents

Build agents with full control using TypeScript.

### Step 1: Create a New Agent Project

Use the Plot CLI to scaffold a new agent:

```bash
npx @plotday/agent create
# or
yarn dlx @plotday/agent create
# or
pnpm dlx @plotday/agent create
```

You'll be prompted for:

- **Package name** (kebab-case, e.g., `my-calendar-agent`)
- **Display name** (human-readable, e.g., "My Calendar Agent")

This creates a new directory with:

```
my-calendar-agent/
├── src/
│   └── index.ts        # Your agent code
├── package.json
├── tsconfig.json
└── plot-agent.json     # Agent configuration
```

### Step 2: Implement Your Agent

Edit `src/index.ts` to add your agent logic:

```typescript
import {
  type Activity,
  ActivityType,
  Agent,
  type Priority,
  type ToolBuilder,
} from "@plotday/agent";
import { Plot } from "@plotday/agent/tools/plot";

export default class MyAgent extends Agent<MyAgent> {
  // Declare tool dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  // Called when the agent is activated for a priority
  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome! Your agent is now active.",
    });
  }

  // Called when an activity is routed to this agent
  async activity(activity: Activity) {
    console.log("Processing activity:", activity.title);
  }
}
```

### Step 3: Test Locally

Build and check for errors:

```bash
npm run build
# or
pnpm build
```

### Step 4: Deploy

You'll need a [Plot account](https://plot.day) to deploy agents.

```bash
# Login to Plot
npm run plot login

# Deploy your agent
npm run deploy
```

Your agent is now deployed and ready to activate in Plot!

---

## Understanding the Project Structure

### Agent File (src/index.ts)

Your agent extends the `Agent` class and implements:

- **`build()`** - Declares tool dependencies
- **`activate()`** - Initialization when added to a priority
- **`deactivate()`** - Cleanup when removed from a priority
- **`upgrade()`** - Migration when deploying a new version

### Configuration (plot-agent.json)

Contains agent metadata:

```json
{
  "name": "my-calendar-agent",
  "displayName": "My Calendar Agent",
  "version": "1.0.0",
  "description": "Syncs calendar events to Plot"
}
```

### TypeScript Config (tsconfig.json)

Extends the Builder's base configuration:

```json
{
  "extends": "@plotday/agent/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

---

## Next Steps

Now that you have a basic agent running, explore:

- **[Core Concepts](CORE_CONCEPTS.md)** - Understand agents, tools, and the Plot architecture
- **[Built-in Tools](TOOLS_GUIDE.md)** - Learn about Plot, Store, Integrations, AI, and more
- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own reusable tools
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints and optimization

## Common First Tasks

### Creating Activities

```typescript
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Review pull request",
  note: "Check the new authentication flow",
  links: [
    {
      type: ActivityLinkType.external,
      title: "View PR",
      url: "https://github.com/org/repo/pull/123",
    },
  ],
});
```

### Storing Data

```typescript
// Save
await this.set("last_sync", new Date().toISOString());

// Retrieve
const lastSync = await this.get<string>("last_sync");
```

### Scheduling Tasks

```typescript
// Run immediately
const callback = await this.callback("processData");
await this.runTask(callback);

// Schedule for later
await this.runTask(callback, {
  runAt: new Date("2025-02-01T10:00:00Z"),
});
```

## Need Help?

- **Documentation**: Continue reading the guides
- **Examples**: Check the [examples directory](https://github.com/plotday/plot/tree/main/agents)
- **Issues**: [Report bugs or request features](https://github.com/plotday/plot/issues)
