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
  - Priorities and Activities
  - Best practices and patterns

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Complete reference for all built-in twist tools

  - Plot - Managing activities and priorities
  - Store - Persistent key-value storage
  - Integrations - OAuth authentication
  - Tasks - Background task execution
  - Network - HTTP access and webhooks
  - Callbacks - Persistent function references
  - AI - Language model integration

- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own twist tools
  - Tool class structure
  - Lifecycle methods
  - Dependencies and configuration
  - Complete examples and best practices
  - Publishing and sharing

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

- **Classes** - Twist, Tool, and all built-in tool classes
- **Interfaces** - Activity, Priority, Contact, and data structures
- **Enums** - ActivityType, ActorType, and other enumerations
- **Type Aliases** - Helper types and utilities

## Quick Links

- [Plot Website](https://plot.day)
- [GitHub Repository](https://github.com/plotday/plot)
- [NPM Package](https://www.npmjs.com/package/@plotday/twister)
- [Report Issues](https://github.com/plotday/plot/issues)

## Examples

Check out these examples to get started:

### Simple Note Twist

```typescript
import {
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class WelcomeTwist extends Twist<WelcomeTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome to Plot! 👋",
    });
  }
}
```

### Calendar Sync Twist

```typescript
import { type Activity, type ToolBuilder, Twist } from "@plotday/twister";
import { Network } from "@plotday/twister/tools/network";
import { Plot } from "@plotday/twister/tools/plot";

export default class CalendarTwist extends Twist<CalendarTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      network: build(Network, {
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    // Set up webhook for calendar updates
    const webhookUrl = await this.tools.network.createWebhook(
      "onCalendarUpdate",
      { priorityId: priority.id }
    );

    await this.set("webhook_url", webhookUrl);
  }
}
```

## Need Help?

- **Documentation Questions**: Read through the guides above
- **Bug Reports**: [Open an issue](https://github.com/plotday/plot/issues)
- **Feature Requests**: [Start a discussion](https://github.com/plotday/plot/discussions)

## License

MIT © Plot Technologies Inc.
