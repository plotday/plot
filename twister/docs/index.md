Welcome to the Plot Twist Creator documentation! This comprehensive guide will help you build powerful Twists that organize and prioritize your work.

## What are Plot Twists?

Plot Twists are smart automations that connect, organize, and prioritize your work. They implement opinionated workflows, integrate with external services, and help you stay organized across all your apps and messages.

## Documentation Structure

### Getting Started

- **[Getting Started Guide](GETTING_STARTED.md)** - Complete walkthrough for building your first twist
  - No-code twist creation with `plot-twist.md`
  - Developer quick start with TypeScript
  - Project structure and setup

### Core Documentation

- **[Core Concepts](CORE_CONCEPTS.md)** - Understanding the Plot architecture

  - Twists and their lifecycle
  - Twist tools and dependencies
  - Focuses, threads, and notes
  - Best practices and patterns

- **[Sync Strategies](SYNC_STRATEGIES.md)** - Data synchronization patterns

  - Upsert via Source and Key (recommended)
  - Create once (fire and forget)
  - Generate and store IDs (advanced)
  - Tags and reactions
  - Choosing the right strategy

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Complete reference for all built-in twist tools

  - Plot - Managing activities and priorities
  - Store - Persistent key-value storage
  - Integrations - OAuth authentication
  - Tasks - Background task execution
  - Network - HTTP access and webhooks
  - Callbacks - Persistent function references
  - AI - Language model integration

- **[Building Connectors](BUILDING_CONNECTORS.md)** - Build external service integrations
  - Connector class structure and lifecycle
  - OAuth and channel management
  - Data sync and batch processing
  - Complete examples and best practices

### Reference

- **[CLI Reference](CLI_REFERENCE.md)** - Complete command-line interface documentation

  - Twist management commands
  - Priority management
  - Authentication
  - Deployment

- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints

  - Sandbox limitations
  - Batching long operations
  - Memory and state management
  - Performance optimization

## API Reference

Explore the complete API documentation using the navigation on the left:

- **Classes** - Twist, Connector, Tool, and all built-in tool classes
- **Type Aliases** - Thread, Note, Focus, Contact, and other data structures
- **Enums** - ActorType, ActionType, and other enumerations

## Quick Links

- [Plot Website](https://plot.day)
- [GitHub Repository](https://github.com/plotday/plot)
- [NPM Package](https://www.npmjs.com/package/@plotday/twister)
- [Report Issues](https://github.com/plotday/plot/issues)

## Examples

Check out these examples to get started:

### Simple Note Twist

```typescript
import { type ToolBuilder, Twist } from "@plotday/twister";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

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

### Calendar Sync Twist

```typescript
import { type ToolBuilder, Twist } from "@plotday/twister";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class CalendarTwist extends Twist<CalendarTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
      network: build(Network, {
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
    };
  }

  async activate() {
    // Set up a webhook for calendar updates
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onCalendarUpdate
    );

    await this.set("webhook_url", webhookUrl);
  }

  async onCalendarUpdate(request: WebhookRequest) {
    // Process the calendar change notification
  }
}
```

## Need Help?

- **Documentation Questions**: Read through the guides above
- **Bug Reports**: [Open an issue](https://github.com/plotday/plot/issues)
- **Feature Requests**: [Start a discussion](https://github.com/plotday/plot/discussions)

## License

MIT © Plot Technologies Inc.
