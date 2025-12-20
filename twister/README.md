<p align="center">
  <a href="https://plot.day" target="_blank" rel="noopener noreferrer">
    <img width="48" height="48" alt="favicon" src="https://github.com/user-attachments/assets/f38501fd-bb37-4671-a0bc-fd35fa25360d" alt="Plot logo" />
  </a>
</p>
<h1 align="center">
  🌪️ Twister, the Plot Twist Creator
</h1>
<p align="center">
  The official package for building <a href="https://plot.day">Plot</a> Twists -<br/>
  smart automations that connect, organize, and prioritize your work.
</p>

<p align="center">
  <a href="https://twist.plot.day"><strong>📚 Full Documentation →</strong></a>
</p>

## Quick Start

Choose your path:

- **[No Code](#no-code-quick-start)** - Write natural language, deploy in minutes
- **[TypeScript](#developer-quick-start)** - Full control with code

### No-Code Quick Start

Describe your twist and Plot will do the rest.

**1. Create `plot-twist.md`:**

```markdown
# My Calendar Twist

I want a twist that:

- Syncs my Google Calendar events into Plot
- Creates tasks for upcoming meetings
- Sends reminders 10 minutes before meetings
```

**2. Deploy:**

```bash
npx @plotday/twister login
npx @plotday/twister deploy
```

That's it! [Learn more →](https://twist.plot.day/documents/Getting_Started.html#no-code-twists)

### Developer Quick Start

Build twists with TypeScript for maximum flexibility.

**1. Create a new twist:**

```bash
npx @plotday/twister create
```

**2. Implement your twist:**

```typescript
import {
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome! Your twist is now active.",
      notes: [
        {
          content: "Your twist is ready to use. Check out the [documentation](https://twist.plot.day) to learn more.",
        },
      ],
    });
  }
}
```

**3. Deploy:**

```bash
npm run plot login
npm run deploy
```

[Complete guide →](https://twist.plot.day/documents/Getting_Started.html)

---

## Core Concepts

### Twists

Twists are smart automations that connect, organize, and prioritize your work. They implement opinionated workflows and respond to lifecycle events.

```typescript
// Lifecycle methods
async activate(priority)   // When twist is added to a priority
async deactivate()         // When twist is removed
async upgrade()            // When new version is deployed
```

### Twist Tools

Twist tools provide capabilities to twists. They are usually unopinionated and do nothing on their own. Use built-in tools or create your own.

**Built-in Tools:**

- **Plot** - Manage activities and priorities
- **Store** - Persistent key-value storage
- **AI** - Language models with structured output
- **Integrations** - OAuth authentication
- **Network** - HTTP access and webhooks
- **Tasks** - Background task execution
- **Callbacks** - Persistent function references

[View all tools →](https://twist.plot.day/documents/Built-in_Tools.html)

### Activities and Notes

**Activity** represents something done or to be done (a task, event, or conversation).
**Notes** represent updates and details on that activity.

Think of an **Activity as a thread** and **Notes as messages in that thread**. Always create activities with an initial note, and add notes for updates rather than creating new activities.

```typescript
// Create an activity with an initial note (thread with first message)
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review pull request",
  source: "github:pr:123", // For deduplication
  notes: [
    {
      content: "New PR ready for review",
      links: [
        {
          type: ActivityLinkType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/123",
        },
      ],
    },
  ],
});

// Add a note to existing activity (add message to thread)
await this.tools.plot.createNote({
  activity: { id: activityId },
  content: "LGTM! Approved ✅",
});
```

[Learn more →](https://twist.plot.day/documents/Core_Concepts.html)

---

## CLI Commands

```bash
# Authentication
plot login

# Twist management
plot create                    # Create new twist project
plot generate                  # Generate code from plot-twist.md
plot deploy                    # Deploy to Plot
plot logs                      # Stream real-time twist logs

# Priority management
plot priority list             # List all priorities
plot priority create           # Create new priority
```

[Complete CLI reference →](https://twist.plot.day/documents/CLI_Reference.html)

---

## Documentation

**[📚 Full Documentation at twist.plot.day](https://twist.plot.day)**

### Guides

- [Getting Started](https://twist.plot.day/documents/Getting_Started.html) - Complete walkthrough
- [Core Concepts](https://twist.plot.day/documents/Core_Concepts.html) - Twists, tools, and architecture
- [Built-in Tools](https://twist.plot.day/documents/Built-in_Tools.html) - Plot, Store, AI, and more
- [Building Custom Tools](https://twist.plot.day/documents/Building_Custom_Tools.html) - Create reusable twist tools
- [Runtime Environment](https://twist.plot.day/documents/Runtime_Environment.html) - Execution constraints and optimization
- [Advanced Topics](https://twist.plot.day/documents/Advanced.html) - Complex patterns and techniques

### Reference

- [CLI Reference](https://twist.plot.day/documents/CLI_Reference.html) - Complete command documentation
- [API Reference](https://twist.plot.day) - TypeDoc-generated API docs

---

## Examples

### Simple Note Twist

```typescript
export default class WelcomeTwist extends Twist<WelcomeTwist> {
  build(build: ToolBuilder) {
    return { plot: build(Plot) };
  }

  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome to Plot! 👋",
      notes: [
        {
          content: "This twist will help you get started with Plot.",
        },
      ],
    });
  }
}
```

### GitHub Integration

```typescript
export default class GitHubTwist extends Twist<GitHubTwist> {
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

[More examples →](https://twist.plot.day/documents/Getting_Started.html)

---

## TypeScript Configuration

Extend the Twist Creator's base configuration in your `tsconfig.json`:

```json
{
  "extends": "@plotday/twister/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

---

## Support

- **Documentation**: [twist.plot.day](https://twist.plot.day)
- **Issues**: [github.com/plotday/plot/issues](https://github.com/plotday/plot/issues)
- **Website**: [plot.day](https://plot.day)

---

## License

MIT © Plot Technologies Inc.
