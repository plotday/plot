# Plot Agent SDK

The official SDK for building Plot agents - intelligent assistants that organize and prioritize your activities from all your apps and messages.

## Installation

```bash
npm install @plotday/sdk
# or
yarn add @plotday/sdk
# or
pnpm add @plotday/sdk
```

## Quick Start

### 1. Create a New Agent

Use the Plot CLI to scaffold a new agent:

```bash
npx @plotday/sdk agent create
```

This will prompt you for:

- Agent ID (from the Plot Agent Builder)
- Package name (kebab-case)
- Display name (human-readable)

### 2. Implement Your Agent

Edit `src/index.ts` to add your agent logic:

```typescript
import {
  type Activity,
  ActivityType,
  Agent,
  type Tools,
  createAgent,
} from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

export default createAgent(
  class extends Agent {
    private plot: Plot;

    constructor(tools: Tools) {
      super();
      this.plot = tools.get(Plot);
    }

    async activate(priority: { id: string }) {
      // Called when the agent is activated for a priority
      await this.plot.createActivity({
        type: ActivityType.Note,
        title: "Welcome! Your agent is now active.",
      });
    }

    async activity(activity: Activity) {
      // Called when an activity is routed to this agent
      console.log("Processing activity:", activity.title);
    }
  }
);
```

### 3. Deploy Your Agent

```bash
npm run deploy
```

## Core Concepts

### Agents

Agents are the main building blocks of Plot. They respond to events and manage activities within priorities.

**Key Methods:**

- `activate(priority)` - Called when the agent is activated for a priority
- `activity(activity)` - Called when an activity is routed to the agent
- `call(name, args, context)` - Dynamically invoke agent methods (used for callbacks)

### Tools

Tools provide functionality to agents. They can be:

- **Built-in Tools** - Core Plot functionality (Plot, Store, Auth, etc.)
- **Regular Tools** - Reusable integrations (GoogleCalendar, OutlookCalendar, etc.)

Access tools via the `tools.get()` method in your agent constructor:

```typescript
constructor(tools: Tools) {
  super();
  this.plot = tools.get(Plot);
  this.store = tools.get(Store);
  this.googleCalendar = tools.get(GoogleCalendar);
}
```

### Activities

Activities are the core data type in Plot, representing tasks, events, and notes.

```typescript
await this.plot.createActivity({
  type: ActivityType.Task,
  title: "Review pull request",
  start: new Date(),
  links: [
    {
      type: ActivityLinkType.external,
      title: "View PR",
      url: "https://github.com/org/repo/pull/123",
    },
  ],
});
```

## Built-in Tools

### Plot

Core tool for creating and managing activities and priorities.

```typescript
import { Plot } from "@plotday/sdk/tools/plot";

// Create activities
await this.plot.createActivity({
  type: ActivityType.Task,
  title: "My task",
});

// Update activities
await this.plot.updateActivity(activity.id, {
  doneAt: new Date(),
});

// Delete activities
await this.plot.deleteActivity(activity.id);

// Create priorities
await this.plot.createPriority({
  title: "Work",
});
```

### Store

Persistent key-value storage for agent state.

```typescript
import { Store } from "@plotday/sdk/tools/store";

// Save data
await this.store.set("sync_token", token);

// Retrieve data
const token = await this.store.get<string>("sync_token");

// Clear data
await this.store.clear("sync_token");
await this.store.clearAll();
```

### Auth

OAuth authentication for external services.

```typescript
import { Auth, AuthLevel, AuthProvider } from "@plotday/sdk/tools/auth";

// Request authentication
const authLink = await this.auth.request(
  {
    provider: AuthProvider.Google,
    level: AuthLevel.User,
    scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
  },
  {
    functionName: "onAuthComplete",
    context: { provider: "google" },
  }
);

// Get access token
const authToken = await this.auth.get(authorization);
```

### Run

Queue background tasks and scheduled operations.

```typescript
import { Run } from "@plotday/sdk/tools/run";

// Execute immediately
await this.run.now("syncCalendar", { calendarId: "primary" });

// Schedule for later
await this.run.at(new Date("2025-01-15T10:00:00Z"), "sendReminder", {
  userId: "123",
});
```

### Webhook

Register webhooks for real-time notifications.

```typescript
import { Webhook } from "@plotday/sdk/tools/webhook";

// Register webhook
const webhookUrl = await this.webhook.register(
  "onCalendarUpdate",
  { calendarId: "primary" }
);

// Handle webhook
async onCalendarUpdate(request: WebhookRequest, context: any) {
  const payload = await request.json();
  // Process webhook
}

// Unregister webhook
await this.webhook.unregister(webhookUrl);
```

### Callback

Create persistent function references for webhooks and auth flows.

```typescript
import { CallbackTool } from "@plotday/sdk/tools/callback";

// Create callback
const token = await this.callback.create("handleEvent", {
  eventType: "calendar_sync",
});

// Execute callback
const result = await this.callback.call(token, {
  data: eventData,
});

// Delete callback
await this.callback.delete(token);
```

## Regular Tools

### Google Calendar

Sync with Google Calendar.

```typescript
import { GoogleCalendar } from "@plotday/sdk/tools/google-calendar";

// Get calendars
const calendars = await this.googleCalendar.getCalendars(authToken);

// Start syncing
await this.googleCalendar.startSync(authToken, calendarId, "onCalendarEvent", {
  options: { timeMin: new Date() },
});

// Stop syncing
await this.googleCalendar.stopSync(authToken, calendarId);
```

### Outlook Calendar

Sync with Microsoft Outlook/Microsoft 365 Calendar.

```typescript
import { OutlookCalendar } from "@plotday/sdk/tools/outlook-calendar";

// Similar API to GoogleCalendar
const calendars = await this.outlookCalendar.getCalendars(authToken);
await this.outlookCalendar.startSync(authToken, calendarId, "onEvent");
```

## CLI Commands

The Plot CLI provides commands for managing agents:

### Authentication

```bash
plot login
```

Authenticate with Plot to generate an API token.

### Agent Management

```bash
# Create a new agent
plot agent create [options]

# Check for errors
plot agent lint [--dir <directory>]

# Deploy agent
plot agent deploy [options]

# Link agent to priority
plot agent link [--priority-id <id>]
```

### Priority Management

```bash
# List priorities
plot priority list

# Create priority
plot priority create [--name <name>] [--parent-id <id>]
```

## Examples

See the [examples](./examples) directory for complete agent implementations:

- **Hello World** - Basic agent that creates a welcome activity
- **Calendar Sync** - Sync Google Calendar events to Plot
- **Task Manager** - Create and manage tasks with custom logic

## TypeScript Configuration

When creating an agent, Plot provides a base TypeScript configuration. Extend it in your `tsconfig.json`:

```json
{
  "extends": "@plotday/sdk/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

## Runtime Limitations

Agents run in a sandboxed Cloudflare Workers environment with:

- **CPU Time**: ~10 seconds per invocation
- **Memory**: 128MB
- **Storage**: Use the Store tool for persistence

For long-running operations, break work into chunks using the Run tool:

```typescript
async startSync(calendarId: string) {
  // Save state
  await this.store.set("sync_state", { calendarId, page: 1 });

  // Queue first batch
  await this.run.now("syncBatch", { calendarId, page: 1 });
}

async syncBatch(context: { calendarId: string; page: number }) {
  // Process one batch
  const hasMore = await processBatch(context.calendarId, context.page);

  if (hasMore) {
    // Queue next batch
    await this.run.now("syncBatch", {
      calendarId: context.calendarId,
      page: context.page + 1
    });
  }
}
```

## Support

- **Issues**: [https://github.com/plotday/plot/issues](https://github.com/plotday/plot/issues)

## License

MIT © Plot
