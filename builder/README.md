<p align="center">
  <a href="https://plot.day" target="_blank" rel="noopener noreferrer">
    <img width="48" height="48" alt="favicon" src="https://github.com/user-attachments/assets/f38501fd-bb37-4671-a0bc-fd35fa25360d" alt="Plot logo" />
  </a>
</p>
<h1 align="center">
  Plot Agent Builder
</h1>
<p align="center">
  The official Builder for building <a href="https://plot.day">Plot</a> agents -<br/>
  custom code that organizes and prioritizes all your messages, tasks, and apps.
</p>

<p align="center">
  <a href="https://build.plot.day"><strong>📚 Full Documentation →</strong></a>
</p>

## Quick Start

Choose your path:

- **[No Code](#no-code-quick-start)** - Write natural language, deploy in minutes
- **[TypeScript](#developer-quick-start)** - Full control with code

### No-Code Quick Start

Create agents using natural language - no programming required!

**1. Create `plot-agent.md`:**

```markdown
# My Calendar Agent

I want an agent that:

- Syncs my Google Calendar events into Plot
- Creates tasks for upcoming meetings
- Sends reminders 10 minutes before meetings
```

**2. Deploy:**

```bash
npx @plotday/agent login
npx @plotday/agent deploy
```

That's it! [Learn more →](https://build.plot.day/documents/Getting_Started.html#no-code-agents)

### Developer Quick Start

Build agents with TypeScript for maximum flexibility.

**1. Create a new agent:**

```bash
npx @plotday/agent create
```

**2. Implement your agent:**

```typescript
import {
  ActivityType,
  Agent,
  type Priority,
  type ToolBuilder,
} from "@plotday/agent";
import { Plot } from "@plotday/agent/tools/plot";

export default class MyAgent extends Agent<MyAgent> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome! Your agent is now active.",
    });
  }
}
```

**3. Deploy:**

```bash
npm run plot login
npm run deploy
```

[Complete guide →](https://build.plot.day/documents/Getting_Started.html)

---

## Core Concepts

### Agents

Agents implement integrations and automations. They respond to lifecycle events and process activities.

```typescript
// Lifecycle methods
async activate(priority)   // When agent is added to a priority
async deactivate()         // When agent is removed
async upgrade()            // When new version is deployed
```

### Tools

Tools provide capabilities to agents. Use built-in tools or create your own.

**Built-in Tools:**

- **Plot** - Manage activities and priorities
- **Store** - Persistent key-value storage
- **AI** - Language models with structured output
- **Integrations** - OAuth authentication
- **Network** - HTTP access and webhooks
- **Tasks** - Background task execution
- **Callbacks** - Persistent function references

[View all tools →](https://build.plot.day/documents/Built-in_Tools.html)

### Activities

The core data type representing tasks, events, and notes.

```typescript
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Review pull request",
  links: [
    {
      type: ActivityLinkType.external,
      title: "View PR",
      url: "https://github.com/org/repo/pull/123",
    },
  ],
});
```

[Learn more →](https://build.plot.day/documents/Core_Concepts.html)

---

## CLI Commands

```bash
# Authentication
plot login

# Agent management
plot create                    # Create new agent project
plot generate                  # Generate code from plot-agent.md
plot deploy                    # Deploy to Plot
plot logs                      # Stream real-time agent logs

# Priority management
plot priority list             # List all priorities
plot priority create           # Create new priority
```

[Complete CLI reference →](https://build.plot.day/documents/CLI_Reference.html)

---

## Documentation

**[📚 Full Documentation at build.plot.day](https://build.plot.day)**

### Guides

- [Getting Started](https://build.plot.day/documents/Getting_Started.html) - Complete walkthrough
- [Core Concepts](https://build.plot.day/documents/Core_Concepts.html) - Agents, tools, and architecture
- [Built-in Tools](https://build.plot.day/documents/Built-in_Tools.html) - Plot, Store, AI, and more
- [Building Custom Tools](https://build.plot.day/documents/Building_Custom_Tools.html) - Create reusable tools
- [Runtime Environment](https://build.plot.day/documents/Runtime_Environment.html) - Execution constraints and optimization
- [Advanced Topics](https://build.plot.day/documents/Advanced.html) - Complex patterns and techniques

### Reference

- [CLI Reference](https://build.plot.day/documents/CLI_Reference.html) - Complete command documentation
- [API Reference](https://build.plot.day) - TypeDoc-generated API docs

---

## Examples

### Simple Note Agent

```typescript
export default class WelcomeAgent extends Agent<WelcomeAgent> {
  build(build: ToolBuilder) {
    return { plot: build(Plot) };
  }

  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome to Plot! 👋",
    });
  }
}
```

### GitHub Integration

```typescript
export default class GitHubAgent extends Agent<GitHubAgent> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      network: build(Network, {
        urls: ["https://api.github.com/*"],
      }),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    // Set up webhook for issue updates
    const webhookUrl = await this.tools.network.createWebhook("onIssueUpdate");
    await this.set("webhook_url", webhookUrl);
  }

  async onIssueUpdate(request: WebhookRequest) {
    // Sync GitHub issues to Plot activities
  }
}
```

[More examples →](https://build.plot.day/documents/Getting_Started.html)

---

## TypeScript Configuration

Extend the Builder's base configuration in your `tsconfig.json`:

```json
{
  "extends": "@plotday/agent/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

---

## Support

- **Documentation**: [build.plot.day](https://build.plot.day)
- **Issues**: [github.com/plotday/plot/issues](https://github.com/plotday/plot/issues)
- **Website**: [plot.day](https://plot.day)

---

## License

MIT © Plot Technologies Inc.
