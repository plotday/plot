# Plot Agent SDK

The official SDK for building Plot agents - intelligent assistants that organize and prioritize your activities from all your apps and messages.

## Quick Start

### 1. Create a New Agent

Use the Plot CLI to scaffold a new agent:

```bash
npx @plotday/sdk agent create
# or
yarn dlx @plotday/sdk agent create
# or
pnpm dlx @plotday/sdk agent create
```

This will prompt you for:

- Package name (kebab-case)
- Display name (human-readable)

### 2. Implement Your Agent

Edit `src/index.ts` to add your agent logic:

```typescript
import { type Activity, ActivityType, Agent, type Tools } from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

export default class extends Agent {
  private plot: Plot;

  constructor(id: string, tools: Tools) {
    super(id, tools);
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
```

### 3. Deploy Your Agent

```bash
npm run deploy
```

## Core Concepts

### Agents

Agents implement integrations and automations in Plot. They are added to priorities to manage activities.

**Key Methods:**

- `activate(priority)` - Called when the agent is activated for a priority
- `activity(activity, changes)` - Called when an activity is routed to the agent

### Priorities and Activities

Activities are the core data type in Plot, representing tasks, events, and notes.

```typescript
await this.plot.createActivity({
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

Activities are grouped within nested contexts called Priorities (e.g. Work, Project X).

## Tools

Tools provide functionality to agents. They can be:

- **Built-in Tools** - Core Plot functionality (Plot, Store, Auth, etc.).
- **Custom Tools** - Extra packages that add capabilities using the built-in tools. They often implement integrations with external services (Google Calendar, Outlook, etc.).

Access tools via the `tools.get()` method in your agent constructor. Store, Run, and Callback methods are available directly on the Agent class:

```typescript
constructor(id: string, tools: Tools) {
  super(id, tools);
  this.plot = tools.get(Plot);
  this.googleCalendar = tools.get(GoogleCalendar);
  // Store, Run, and Callback methods are available directly:
  // this.get(), this.set(), this.callback(), this.run(), etc.
}
```

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

Persistent key-value storage for agent state. Store methods are available directly on Agent and Tool classes.

```typescript
// Save data (no import needed - available directly)
await this.set("sync_token", token);

// Retrieve data
const token = await this.get<string>("sync_token");

// Clear data
await this.clear("sync_token");
await this.clearAll();
```

### Auth

OAuth authentication for external services.

```typescript
import { Auth, AuthLevel, AuthProvider, type Authorization } from "@plotday/sdk/tools/auth";

// Request authentication
const authCallback = await this.callback("onAuthComplete", { provider: "google" });
const authLink = await this.auth.request(
  {
    provider: AuthProvider.Google,
    level: AuthLevel.User,
    scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
  },
  authCallback,
);

// Handle auth completion
async onAuthComplete(authorization: Authorization, context: any) {
  // Get access token
  const authToken = await this.auth.get(authorization);
  console.log("Access token:", authToken.token);
}
```

### Run

Queue background tasks and scheduled operations. Run methods are available directly on Agent and Tool classes.

```typescript
// Execute immediately (no import needed - available directly)
const callback = await this.callback("syncCalendar", { calendarId: "primary" });
await this.run(callback);

// Schedule for later
const reminderCallback = await this.callback("sendReminder", { userId: "123" });
await this.run(reminderCallback, { runAt: new Date("2025-01-15T10:00:00Z") });
```

### Webhook

Create webhook endpoints for real-time notifications from external services.

```typescript
import { Webhook, type WebhookRequest } from "@plotday/sdk/tools/webhook";

// Create webhook endpoint
const webhookUrl = await this.webhook.create(
  "onCalendarUpdate",
  { calendarId: "primary" }
);

// Handle webhook requests
async onCalendarUpdate(request: WebhookRequest, context: any) {
  console.log("Webhook received:", request.method, request.body);
  // Process webhook
}

// Delete webhook endpoint
await this.webhook.delete(webhookUrl);
```

### Callback

Create persistent function references for webhooks and auth flows. Callback methods are available directly on Agent and Tool classes.

```typescript
// Create callback (no import needed - available directly)
const token = await this.callback("handleEvent", {
  eventType: "calendar_sync",
});

// Execute callback
const result = await this.call(token, {
  data: eventData,
});

// Delete callback
await this.deleteCallback(token);
await this.deleteAllCallbacks(); // Delete all
```

### AI

Prompt large language models with structured output support.

```typescript
import { AI, AIModel } from "@plotday/sdk/tools/ai";
import { Type } from "typebox";

// Simple text generation
const response = await this.ai.prompt({
  model: AIModel.GPT_4O_MINI,
  prompt: "Explain quantum computing in simple terms",
});
console.log(response.text);

// Structured output with type-safe schemas
const schema = Type.Object({
  category: Type.Union([
    Type.Literal("work"),
    Type.Literal("personal"),
    Type.Literal("urgent"),
  ]),
  priority: Type.Number({ minimum: 1, maximum: 5 }),
  summary: Type.String({ description: "Brief summary" }),
});

const response = await this.ai.prompt({
  model: AIModel.GPT_4O,
  prompt: "Categorize this email: Meeting at 3pm tomorrow",
  outputSchema: schema,
});

// Fully typed output!
console.log(response.output.category); // "work" | "personal" | "urgent"
console.log(response.output.priority); // number

// Tool calling
const response = await this.ai.prompt({
  model: AIModel.GPT_4O_MINI,
  prompt: "What's 15% of $250?",
  tools: {
    calculate: {
      description: "Perform calculations",
      parameters: Type.Object({
        expression: Type.String(),
      }),
      execute: async ({ expression }) => {
        return { result: eval(expression) };
      },
    },
  },
});
```

**Structured Output with Typebox:**

The AI tool uses [Typebox](https://github.com/sinclairzx81/typebox) for schema definition. Typebox provides JSON Schema with full TypeScript type inference:

```typescript
import { Type } from "typebox";

// Define schema
const PersonSchema = Type.Object({
  name: Type.String(),
  age: Type.Number(),
  email: Type.Optional(Type.String({ format: "email" })),
});

// Use in AI prompt
const response = await this.ai.prompt({
  model: AIModel.GPT_4O,
  prompt: "Extract: John Doe, 30 years old, john@example.com",
  outputSchema: PersonSchema,
});

// TypeScript knows the exact shape!
response.output.name; // string
response.output.age; // number
response.output.email; // string | undefined
```

**Available Models:**

- **OpenAI**: `GPT_4O`, `GPT_4O_MINI`, `GPT_4_TURBO`, `GPT_35_TURBO`
- **Anthropic**: `CLAUDE_SONNET_4_5`, `CLAUDE_35_SONNET`, `CLAUDE_3_OPUS`
- **Google**: `GEMINI_25_FLASH`
- **Workers AI**: `LLAMA_33_70B`, `LLAMA_31_8B`, `MISTRAL_7B`

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

## TypeScript Configuration

When creating an agent, Plot provides a base TypeScript configuration. Extend it in your `tsconfig.json`:

```json
{
  "extends": "@plotday/sdk/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

## Runtime Limitations

Agents run in a sandboxed environment with limited resources. For long-running operations, break work into chunks using the run method:

```typescript
async startSync(calendarId: string) {
  // Save state
  await this.set("sync_state", { calendarId, page: 1 });

  // Queue first batch
  const callback = await this.callback("syncBatch", { calendarId, page: 1 });
  await this.run(callback);
}

async syncBatch(args: any, context: { calendarId: string; page: number }) {
  // Process one batch
  const hasMore = await processBatch(context.calendarId, context.page);

  if (hasMore) {
    // Queue next batch
    const callback = await this.callback("syncBatch", {
      calendarId: context.calendarId,
      page: context.page + 1
    });
    await this.run(callback);
  }
}
```

## Support

- **Issues**: [https://github.com/plotday/plot/issues](https://github.com/plotday/plot/issues)

## License

MIT © Plot Technologies Inc.
