---
title: Getting Started
group: Guides
---

# Getting Started with Plot Twists

This guide will walk you through creating your first Plot Twist. There are two ways to build twists: with natural language (no code) or with TypeScript code for maximum flexibility.

## Choose Your Path

- **[No-Code Twists](#no-code-twists)** - Perfect for non-developers or rapid prototyping
- **[Developer Twists](#developer-twists)** - Full control with TypeScript

---

## No-Code Twists

Create twists using natural language descriptions - no programming required!

### Step 1: Create a plot-twist.md File

Create a file named `plot-twist.md` in your project directory and describe what you want your twist to do:

```markdown
# My Calendar Twist

I want a twist that:

- Syncs my Google Calendar events into Plot as threads
- Creates tasks for upcoming meetings
- Sends me a reminder 10 minutes before each meeting
- Updates thread status when meetings are completed
```

**Be specific about:**

- **Data sources** - Which services to connect (Google Calendar, GitHub, Slack, etc.)
- **Actions** - What the twist should do (create tasks, send notifications, update status)
- **Triggers** - When actions should happen (on new events, on schedule, when threads change)

### Step 2: Deploy Your Twist

You'll need a [Plot account](https://plot.day) to deploy twists.

```bash
# Login to Plot
npx @plotday/twister login

# Deploy directly from your spec
npx @plotday/twister deploy
```

That's it! Your twist is now live in Plot.

### Optional: Generate Code First

If you want to review or customize the generated code before deploying:

```bash
# Generate TypeScript code from your spec
npx @plotday/twister generate

# Review and edit the generated src/index.ts
# Then deploy
npx @plotday/twister deploy
```

The `generate` command creates a complete TypeScript twist that you can modify and extend.

---

## Developer Twists

Build twists with full control using TypeScript.

### Step 1: Create a New Twist Project

Use the Plot CLI to scaffold a new twist:

```bash
npx @plotday/twister create
# or
yarn dlx @plotday/twister create
# or
pnpm dlx @plotday/twister create
```

You'll be prompted for:

- **Package name** (kebab-case, e.g., `my-calendar-twist`)
- **Display name** (human-readable, e.g., "My Calendar Twist")

This creates a new directory with:

```
my-calendar-twist/
├── src/
│   └── index.ts        # Your twist code
├── package.json        # Twist metadata and dependencies
├── tsconfig.json
├── README.md
├── AGENTS.md           # Guide for AI coding assistants
└── CLAUDE.md
```

### Step 2: Implement Your Twist

Edit `src/index.ts` to add your twist logic:

```typescript
import { type Note, type ToolBuilder, Twist } from "@plotday/twister";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  // Declare tool dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
    };
  }

  // Called when the twist is installed
  async activate() {
    await this.tools.plot.createThread({
      title: "Welcome! Your twist is now active.",
      notes: [
        {
          content: "Your twist is ready to use. You can now start creating threads and automating your workflow.",
        },
      ],
    });
  }

  // Called when a note is created on a thread this twist created
  async onNoteCreated(note: Note) {
    console.log("Processing note:", note.content);
  }
}
```

### Step 3: Test Locally

Check for build and lint errors:

```bash
npm run lint
# or
pnpm lint
```

### Step 4: Deploy

You'll need a [Plot account](https://plot.day) to deploy twists.

```bash
# Login to Plot
npx plot login

# Deploy your twist
npm run deploy
```

Your twist is now deployed and ready to activate in Plot!

---

## Understanding the Project Structure

### Twist File (src/index.ts)

Your twist extends the `Twist` class and implements:

- **`build()`** - Declares tool dependencies
- **`activate()`** - Initialization when the twist is installed
- **`deactivate()`** - Cleanup when the twist is uninstalled
- **`upgrade()`** - Migration when deploying a new version

### Configuration (package.json)

Twist metadata lives in `package.json`, including a generated `plotTwistId` that identifies your twist for deployment:

```json
{
  "name": "my-calendar-twist",
  "displayName": "My Calendar Twist",
  "description": "Syncs calendar events to Plot",
  "plotTwistId": "generated-uuid"
}
```

### TypeScript Config (tsconfig.json)

Extends the Twist Creator's base configuration:

```json
{
  "extends": "@plotday/twister/tsconfig.base.json",
  "include": ["src/*.ts"]
}
```

---

## Next Steps

Now that you have a basic twist running, explore:

- **[Core Concepts](CORE_CONCEPTS.md)** - Understand twists, tools, and the Plot architecture
- **[Built-in Tools](TOOLS_GUIDE.md)** - Learn about Plot, Store, Integrations, AI, and more
- **[Building Connectors](BUILDING_CONNECTORS.md)** - Build external service integrations
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints and optimization

## Common First Tasks

### Understanding Threads and Notes

A **Thread** represents something done or to be done (a task, event, or conversation), while **Notes** represent the updates and details on that thread.

Think of a **Thread as a thread** on a messaging platform, and **Notes as the messages in that thread**. Always create threads with an initial note, and add notes for updates rather than creating new threads.

### Creating Threads

Always create threads with an initial note. The `notes` array can contain multiple notes (messages in the thread).

**Data Sync Tip:** When syncing from external systems, build a connector and use `Link.sources` for automatic deduplication and `Note.key` for upsertable notes. See the [Sync Strategies](SYNC_STRATEGIES.md) guide for detailed patterns.

```typescript
import { ActionType } from "@plotday/twister";

await this.tools.plot.createThread({
  title: "Review pull request",
  notes: [
    {
      key: "description", // Using key enables upserts
      content: "Please review the authentication changes and ensure they follow security best practices.",
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
```

#### Scheduling Threads

Threads appear on the user's agenda when they have a schedule. Pass `schedules` when creating the thread, or call `createSchedule()` later:

```typescript
// Scheduled (recurring) event
await this.tools.plot.createThread({
  title: "Team standup",
  notes: [{ content: "Daily sync meeting" }],
  schedules: [
    {
      start: new Date("2025-02-01T10:00:00Z"),
      end: new Date("2025-02-01T10:30:00Z"),
      recurrenceRule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
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
// Run immediately (in a new execution with a fresh request limit)
const callback = await this.callback(this.processData);
await this.runTask(callback);

// Schedule for later
await this.runTask(callback, {
  runAt: new Date("2025-02-01T10:00:00Z"),
});
```

### Best Practices

#### Always Include Notes with Threads

**Important:** Always create Threads with at least one initial Note. The `title` and `preview` are brief summaries that may be truncated in the UI. Detailed information should go in Notes.

```typescript
// ✅ Good - Thread with detailed Note
await this.tools.plot.createThread({
  title: "Deploy v2.0",
  notes: [
    {
      content: "Deployment checklist:\n- Run database migrations\n- Update environment variables\n- Deploy backend services\n- Deploy frontend\n- Run smoke tests",
      actions: [
        {
          type: ActionType.external,
          title: "Deployment Guide",
          url: "https://docs.example.com/deploy",
        },
      ],
    },
  ],
});

// ❌ Bad - No detailed information
await this.tools.plot.createThread({
  title: "Deploy v2.0",
  // Missing Notes with context and steps
});
```

#### Add Notes to Existing Threads for Related Content

For conversations, email threads, or workflows, add Notes to the existing Thread instead of creating new Threads.

**Recommended Pattern:** Store the thread ID when you create the thread, then add notes by ID. A unique `Note.key` per message makes note writes upserts, so re-processing the same message never creates duplicates:

```typescript
async onNewMessage(message: Message, conversationId: string) {
  // Look up the thread for this conversation (created earlier)
  let threadId = await this.get<Uuid>(`thread_${conversationId}`);

  if (!threadId) {
    // First message - create the thread with the message as its initial note
    threadId = await this.tools.plot.createThread({
      title: message.subject || "New conversation",
      notes: [
        {
          key: `message-${message.id}`, // Unique key per message enables upserts
          content: message.text,
        },
      ],
    });
    await this.set(`thread_${conversationId}`, threadId);
    return;
  }

  // Follow-up message - add a note to the existing thread
  await this.tools.plot.createNote({
    thread: { id: threadId },
    key: `message-${message.id}`,
    content: message.text,
  });
}
```

**For connectors:** When syncing from an external service, you don't need to store thread IDs at all — save links with `integrations.saveLink()` using `Link.sources` for deduplication, and reference threads by source (`thread: { source: ... }`) when creating notes.

See [Sync Strategies](SYNC_STRATEGIES.md) for more patterns and guidance on choosing the right approach.

See [Core Concepts - Best Practices](CORE_CONCEPTS.md#best-practices-for-threads-and-notes) for more details.

## Need Help?

- **Documentation**: Continue reading the guides
- **Examples**: Check the [examples directory](https://github.com/plotday/plot/tree/main/twists)
- **Issues**: [Report bugs or request features](https://github.com/plotday/plot/issues)
