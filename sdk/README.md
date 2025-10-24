<p align="center">
  <a href="https://linear.app" target="_blank" rel="noopener noreferrer">
    <img width="48" height="48" alt="favicon" src="https://github.com/user-attachments/assets/f38501fd-bb37-4671-a0bc-fd35fa25360d" alt="Plot logo" />
  </a>
</p>
<h1 align="center">
  Plot Agent SDK
</h1>
<p align="center">
  The official SDK for building <a href="https://plot.day">Plot</a> agents -<br/>
  custom code that organizes and prioritizes all your messages, tasks, and apps.
</p>

## Two Ways to Build Agents

You can create Plot agents in two ways:

- **No Code Required** - Write a natural language description in a `plot-agent.md` file and deploy it directly. Perfect for non-developers or rapid prototyping. [Jump to No-Code Quick Start](#quick-start-no-code)
- **Full Control with Code** - Write custom TypeScript code for complete flexibility and advanced integrations. [Jump to Developer Quick Start](#quick-start-for-developers)

## Quick Start (No Code)

Create an agent using natural language - no coding required.

### 1. Create a `plot-agent.md` File

Create a file named `plot-agent.md` in your project directory and describe what you want your agent to do in plain English:

```markdown
# My Calendar Agent

I want an agent that:

- Syncs my Google Calendar events into Plot as activities
- Creates tasks for upcoming meetings
- Sends me a reminder 10 minutes before each meeting
- Updates activity status when meetings are completed
```

Be specific about:

- What data sources to connect (e.g., Google Calendar, GitHub, Slack)
- What actions to take (e.g., create tasks, send notifications)
- When to trigger actions (e.g., on new events, on schedule, when activities change)

### 2. Deploy Your Agent

You'll need a [Plot account](https://plot.day) to deploy agents.

```bash
# Login to Plot
npx @plotday/sdk login

# Deploy directly from your spec
npx @plotday/sdk agent deploy
```

That's it! Your agent is now live in Plot.

**Optional: Generate Code First**

If you want to see or customize the generated code before deploying:

```bash
# Generate TypeScript code from your spec
npx @plotday/sdk agent generate

# Review and edit the generated src/index.ts
# Then deploy
npx @plotday/sdk agent deploy
```

## Quick Start (For Developers)

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
import { type Activity, ActivityType, Agent, type Priority, type ToolBuilder } from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

export default class MyAgent extends Agent<typeof MyAgent> {
  static Init(tools: ToolBuilder) {
    return {
      plot: tools.init(Plot),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    // Called when the agent is activated for a priority
    await this.tools.plot.createActivity({
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

You'll need a [Plot account](https://plot.day) to deploy agents.

```bash
npm run plot login
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

**Type References:**

- [ActivityType enum](https://github.com/plotday/plot/blob/main/sdk/src/plot.ts#L35-L42) - Note, Task, Event
- [ActivityLinkType enum](https://github.com/plotday/plot/blob/main/sdk/src/plot.ts#L65-L74) - external, auth, hidden, callback
- [Activity type](https://github.com/plotday/plot/blob/main/sdk/src/plot.ts#L216-L288) - Full activity structure

## Tools

Tools provide functionality to agents. They can be:

- **Built-in Tools** - Core Plot functionality (Plot, Store, Integrations, etc.).
- **Custom Tools** - Extra packages that add capabilities using the built-in tools. They often implement integrations with external services (Google Calendar, Outlook, etc.).

Declare tools in the static `Init` method. Store, Tasks, and Callbacks methods are available directly on the Agent class:

```typescript
static Init(tools: ToolBuilder) {
  return {
    plot: tools.init(Plot),
    googleCalendar: tools.init(GoogleCalendar),
  };
}
// Store, Tasks, and Callbacks methods are available directly:
// this.get(), this.set(), this.callback(), this.run(), etc.
```

### Plot

Core tool for creating and managing activities and priorities.

```typescript
import { Plot } from "@plotday/sdk/tools/plot";

// Create activities
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "My task",
});

// Update activities
await this.tools.plot.updateActivity(activity.id, {
  doneAt: new Date(),
});

// Delete activities
await this.tools.plot.deleteActivity(activity.id);

// Create priorities
await this.tools.plot.createPriority({
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

### Integrations

OAuth authentication for external services.

```typescript
import { Integrations, AuthLevel, AuthProvider, type Authorization } from "@plotday/sdk/tools/integrations";

// Request authentication
const authCallback = await this.callback("onAuthComplete", { provider: "google" });
const authLink = await this.tools.integrations.request(
  {
    provider: AuthProvider.Google,
    level: AuthLevel.User,
    scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
  },
  authCallback
);

// Handle auth completion
async onAuthComplete(authorization: Authorization, context: any) {
  // Get access token
  const authToken = await this.tools.integrations.get(authorization);
  console.log("Access token:", authToken?.token);
}
```

**Type References:**

- [AuthProvider enum](https://github.com/plotday/plot/blob/main/sdk/src/tools/integrations.ts#L82-L87) - Google, Microsoft
- [AuthLevel enum](https://github.com/plotday/plot/blob/main/sdk/src/tools/integrations.ts#L94-L99) - Priority, User

### Tasks

Queue background tasks and scheduled operations. Tasks methods are available directly on Agent and Tool classes.

```typescript
// Execute immediately (no import needed - available directly)
const callback = await this.callback("syncCalendar", { calendarId: "primary" });
await this.run(callback);

// Schedule for later
const reminderCallback = await this.callback("sendReminder", { userId: "123" });
await this.run(reminderCallback, { runAt: new Date("2025-01-15T10:00:00Z") });
```

### Network

Request HTTP access permissions and create webhook endpoints for real-time notifications from external services.

```typescript
import { Network, type WebhookRequest } from "@plotday/sdk/tools/network";

// Declare HTTP access in Init method
static Init(tools: ToolBuilder) {
  return {
    network: tools.init(Network, {
      urls: ['https://api.example.com/*']
    })
  };
}

// Create webhook endpoint
const webhookUrl = await this.tools.network.createWebhook(
  "onCalendarUpdate",
  { calendarId: "primary" }
);

// Handle webhook requests
async onCalendarUpdate(request: WebhookRequest, context: any) {
  console.log("Webhook received:", request.method, request.body);
  // Process webhook
}

// Delete webhook endpoint
await this.tools.network.deleteWebhook(webhookUrl);
```

### Callbacks

Create persistent function references for webhooks and auth flows. Callbacks methods are available directly on Agent and Tool classes.

```typescript
// Create callback (no import needed - available directly)
const callback = await this.callback("handleEvent", {
  eventType: "calendar_sync",
});

// Execute callback
const result = await this.run(callback, {
  data: eventData,
});

// Delete callback
await this.deleteCallback(callback);
await this.deleteAllCallbacks(); // Delete all
```

### AI

Prompt large language models with structured output support.

```typescript
import { AI } from "@plotday/sdk/tools/ai";
import { Type } from "typebox";

// Simple text generation with fast, low-cost model
const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "low" },
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

const response = await this.tools.ai.prompt({
  model: { speed: "balanced", cost: "medium" },
  prompt: "Categorize this email: Meeting at 3pm tomorrow",
  outputSchema: schema,
});

// Fully typed output!
console.log(response.output.category); // "work" | "personal" | "urgent"
console.log(response.output.priority); // number

// Tool calling
const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "medium" },
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
const response = await this.tools.ai.prompt({
  model: { speed: "balanced", cost: "medium" },
  prompt: "Extract: John Doe, 30 years old, john@example.com",
  outputSchema: PersonSchema,
});

// TypeScript knows the exact shape!
response.output.name; // string
response.output.age; // number
response.output.email; // string | undefined
```

**Model Selection:**

Use `ModelPreferences` to specify your requirements based on speed and cost tiers:

- **Speed**: `"fast"`, `"balanced"`, or `"capable"`
- **Cost**: `"low"`, `"medium"`, or `"high"`

Plot automatically selects the best available model matching your preferences. See the [AIModel enum](https://github.com/plotday/plot/blob/main/sdk/src/tools/ai.ts#L213-L243) for specific models currently supported.

## CLI Commands

The Plot CLI provides commands for managing agents:

### Authentication

```bash
plot login
```

Authenticate with Plot to generate an API token.

### Agent Management

```bash
# Create a new agent (code-based)
plot agent create [options]

# Generate code from plot-agent.md spec
plot agent generate [--input <path>] [--output <directory>]

# Check for errors
plot agent lint [--dir <directory>]

# Deploy agent (works with code or plot-agent.md)
plot agent deploy [options]

# Link agent to priority
plot agent link [--priority-id <id>]
```

**`plot agent generate`**

Generates fully functional TypeScript agent code from a natural language `plot-agent.md` specification.

- `--input <path>` - Path to plot-agent.md file (default: `./plot-agent.md`)
- `--output <directory>` - Output directory for generated code (default: `./src`)

**`plot agent deploy`**

Deploys an agent to Plot. Automatically detects whether to deploy from:

- A `plot-agent.md` specification file (generates and deploys in one step)
- Compiled TypeScript code in `src/` directory

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
