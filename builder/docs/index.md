Welcome to the Plot Agent Builder documentation! This comprehensive guide will help you build powerful agents that organize and prioritize activities in Plot.

## What are Plot Agents?

Plot agents are intelligent assistants that automatically manage your activities, tasks, and events. They can integrate with external services, process data, and help you stay organized across all your apps and messages.

## Documentation Structure

### Getting Started

- **[Getting Started Guide](GETTING_STARTED.md)** - Complete walkthrough for building your first agent
  - No-code agent creation with `plot-agent.md`
  - Developer quick start with TypeScript
  - Project structure and setup

### Core Documentation

- **[Core Concepts](CORE_CONCEPTS.md)** - Understanding the Plot architecture

  - Agents and their lifecycle
  - Tools and dependencies
  - Priorities and Activities
  - Best practices and patterns

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Complete reference for all built-in tools

  - Plot - Managing activities and priorities
  - Store - Persistent key-value storage
  - Integrations - OAuth authentication
  - Tasks - Background task execution
  - Network - HTTP access and webhooks
  - Callbacks - Persistent function references
  - AI - Language model integration

- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own tools
  - Tool class structure
  - Lifecycle methods
  - Dependencies and configuration
  - Complete examples and best practices
  - Publishing and sharing

### Reference

- **[CLI Reference](CLI_REFERENCE.md)** - Complete command-line interface documentation

  - Agent management commands
  - Priority management
  - Authentication
  - Deployment

- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints

  - Sandbox limitations
  - Batching long operations
  - Memory and state management
  - Performance optimization

- **[Advanced Topics](ADVANCED.md)** - Complex patterns and techniques
  - Multi-agent coordination
  - Error handling
  - Debugging and logging
  - Security best practices

## API Reference

Explore the complete API documentation using the navigation on the left:

- **Classes** - Agent, Tool, and all built-in tool classes
- **Interfaces** - Activity, Priority, Contact, and data structures
- **Enums** - ActivityType, ActorType, and other enumerations
- **Type Aliases** - Helper types and utilities

## Quick Links

- [Plot Website](https://plot.day)
- [GitHub Repository](https://github.com/plotday/plot)
- [NPM Package](https://www.npmjs.com/package/@plotday/agent)
- [Report Issues](https://github.com/plotday/plot/issues)

## Examples

Check out these examples to get started:

### Simple Note Agent

```typescript
import {
  ActivityType,
  Agent,
  type Priority,
  type ToolBuilder,
} from "@plotday/agent";
import { Plot } from "@plotday/agent/tools/plot";

export default class WelcomeAgent extends Agent<WelcomeAgent> {
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

### Calendar Sync Agent

```typescript
import { type Activity, Agent, type ToolBuilder } from "@plotday/agent";
import { Network } from "@plotday/agent/tools/network";
import { Plot } from "@plotday/agent/tools/plot";

export default class CalendarAgent extends Agent<CalendarAgent> {
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
