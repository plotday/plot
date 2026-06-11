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
import { type ToolBuilder, Twist } from "@plotday/twister";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
    };
  }

  async activate() {
    await this.tools.plot.createThread({
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
npx plot login
npm run deploy
```

[Complete guide →](https://twist.plot.day/documents/Getting_Started.html)

---

## Core Concepts

### Twists

Twists are smart automations that connect, organize, and prioritize your work. They implement opinionated workflows and respond to lifecycle events. A twist is installed at the workspace level and owned by a single user.

```typescript
// Lifecycle methods
async activate(context?)   // When the twist is installed
async deactivate()         // When the twist is uninstalled
async upgrade()            // When a new version is deployed
```

### Twist Tools

Twist tools provide capabilities to twists. They are usually unopinionated and do nothing on their own.

**Built-in Tools:**

- **Plot** - Manage threads, notes, and focuses
- **Store** - Persistent key-value storage
- **AI** - Language models with structured output
- **Integrations** - OAuth authentication and channel lifecycle
- **Network** - HTTP access and webhooks
- **Tasks** - Background task execution
- **Callbacks** - Persistent function references

[View all tools →](https://twist.plot.day/documents/Built-in_Tools.html)

External service integrations (Google Calendar, Slack, Linear, etc.) are built as **Connectors** — see [Building Connectors](https://twist.plot.day/documents/Building_Connectors.html).

### Threads and Notes

A **Thread** represents something done or to be done (a task, event, or conversation).
**Notes** represent updates and details on that thread.

Think of a **Thread like a messaging thread** and **Notes as messages in that thread**. Always create threads with an initial note, and add notes for updates rather than creating new threads.

**Data sync:** When syncing from external systems, connectors save **Links** (external items attached to threads) via `integrations.saveLink()`, using `Link.sources` for deduplication and `Note.key` for upsertable notes — no manual ID tracking needed. See the [Sync Strategies guide](https://github.com/plotday/plot/blob/main/twister/docs/SYNC_STRATEGIES.md) for detailed patterns.

```typescript
import { ActionType } from "@plotday/twister";

// Create a thread with an initial note
const threadId = await this.tools.plot.createThread({
  title: "Review pull request",
  notes: [
    {
      key: "description", // Use key for upsertable notes
      content: "New PR ready for review",
      actions: [
        {
          type: ActionType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/123",
        },
      ],
    },
  ],
});

// Add or update a note using key (upserts if key exists)
await this.tools.plot.createNote({
  thread: { id: threadId },
  key: "approval", // Using key enables upserts
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
plot lint                      # Check for build or lint errors
plot build                     # Bundle without deploying
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
- [Sync Strategies](https://github.com/plotday/plot/blob/main/twister/docs/SYNC_STRATEGIES.md) - Data synchronization patterns (upserts, deduplication, ID management)
- [Built-in Tools](https://twist.plot.day/documents/Built-in_Tools.html) - Plot, Store, AI, and more
- [Building Connectors](https://twist.plot.day/documents/Building_Connectors.html) - Build external service integrations
- [Runtime Environment](https://twist.plot.day/documents/Runtime_Environment.html) - Execution constraints and optimization

### Reference

- [CLI Reference](https://twist.plot.day/documents/CLI_Reference.html) - Complete command documentation
- [API Reference](https://twist.plot.day) - TypeDoc-generated API docs

---

## Examples

### Simple Note Twist

```typescript
export default class WelcomeTwist extends Twist<WelcomeTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
    };
  }

  async activate() {
    await this.tools.plot.createThread({
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

### GitHub Connector

```typescript
import { Connector, type ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";

export default class GitHubConnector extends Connector<GitHubConnector> {
  readonly provider = AuthProvider.GitHub;
  readonly scopes = ["repo"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
    };
  }

  async getChannels(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    // Return repositories the user can sync
    const repos = await this.listRepos(token);
    return repos.map((repo) => ({
      id: repo.id,
      title: repo.full_name,
    }));
  }

  async onChannelEnabled(channel: Channel) {
    // Start syncing issues from this repository
  }

  async onChannelDisabled(channel: Channel) {
    // Stop syncing and clean up
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
