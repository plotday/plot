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

- Syncs my Google Calendar events into Plot as activities
- Creates tasks for upcoming meetings
- Sends me a reminder 10 minutes before each meeting
- Updates activity status when meetings are completed
```

**Be specific about:**

- **Data sources** - Which services to connect (Google Calendar, GitHub, Slack, etc.)
- **Actions** - What the twist should do (create tasks, send notifications, update status)
- **Triggers** - When actions should happen (on new events, on schedule, when activities change)

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
├── package.json
├── tsconfig.json
└── plot-twist.json     # Twist configuration
```

### Step 2: Implement Your Twist

Edit `src/index.ts` to add your twist logic:

```typescript
import {
  type Activity,
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  // Declare tool dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  // Called when the twist is activated for a priority
  async activate(priority: Pick<Priority, "id">) {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Welcome! Your twist is now active.",
      notes: [
        {
          content: "Your twist is ready to use. You can now start creating activities and automating your workflow.",
        },
      ],
    });
  }

  // Called when an activity is routed to this twist
  async activity(activity: Activity) {
    console.log("Processing activity:", activity.title);
  }
}
```

### Step 3: Test Locally

Build and check for errors:

```bash
npm run build
# or
pnpm build
```

### Step 4: Deploy

You'll need a [Plot account](https://plot.day) to deploy twists.

```bash
# Login to Plot
npm run plot login

# Deploy your twist
npm run deploy
```

Your twist is now deployed and ready to activate in Plot!

---

## Understanding the Project Structure

### Twist File (src/index.ts)

Your twist extends the `Twist` class and implements:

- **`build()`** - Declares tool dependencies
- **`activate()`** - Initialization when added to a priority
- **`deactivate()`** - Cleanup when removed from a priority
- **`upgrade()`** - Migration when deploying a new version

### Configuration (plot-twist.json)

Contains twist metadata:

```json
{
  "name": "my-calendar-twist",
  "displayName": "My Calendar Twist",
  "version": "1.0.0",
  "description": "Syncs calendar events to Plot"
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
- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own reusable twist tools
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints and optimization

## Common First Tasks

### Understanding Activities and Notes

**Activity** represents something done or to be done (a task, event, or conversation), while **Notes** represent the updates and details on that activity.

Think of an **Activity as a thread** on a messaging platform, and **Notes as the messages in that thread**. Always create activities with an initial note, and add notes for updates rather than creating new activities.

### Creating Activities

Always create activities with an initial note. The `notes` array can contain multiple notes (messages in the thread):

```typescript
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review pull request",
  source: "github:pr:123", // For deduplication
  notes: [
    {
      content: "Please review the authentication changes and ensure they follow security best practices.",
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
```

#### Scheduling States for Actions

**Important:** When creating Actions (tasks), the `start` field determines how they appear in Plot. By default, omitting `start` creates a "Do Now" task. For most integrations, you should explicitly set `start: null` to create backlog items.

```typescript
// "Do Now" - Actionable today (DEFAULT when start is omitted)
// Use for urgent tasks or items actively in progress
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Fix critical bug in production",
  notes: [{ content: "Users reporting login failures" }],
  // Omitting start defaults to current time
});

// "Do Someday" - Backlog item (RECOMMENDED for most synced tasks)
// Use for task backlog, future ideas, non-urgent items
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Refactor authentication module",
  start: null, // Explicitly set to null for backlog
  notes: [{ content: "Technical debt item to address later" }],
});

// "Do Later" - Scheduled for specific date
// Use when task has a specific due date
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Submit expense report",
  start: new Date("2025-01-31"), // Due date
  notes: [{ content: "December expenses need to be submitted by end of month" }],
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
// Run immediately
const callback = await this.callback("processData");
await this.runTask(callback);

// Schedule for later
await this.runTask(callback, {
  runAt: new Date("2025-02-01T10:00:00Z"),
});
```

### Best Practices

#### Always Include Notes with Activities

**Important:** Always create Activities with at least one initial Note. The `title` and `preview` are brief summaries that may be truncated in the UI. Detailed information should go in Notes.

```typescript
// ✅ Good - Activity with detailed Note
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Deploy v2.0",
  notes: [
    {
      note: "Deployment checklist:\n- Run database migrations\n- Update environment variables\n- Deploy backend services\n- Deploy frontend\n- Run smoke tests",
      links: [
        {
          type: ActivityLinkType.external,
          title: "Deployment Guide",
          url: "https://docs.example.com/deploy",
        },
      ],
    },
  ],
});

// ❌ Bad - No detailed information
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Deploy v2.0",
  // Missing Notes with context and steps
});
```

#### Add Notes to Existing Activities for Related Content

For conversations, email threads, or workflows, add Notes to the existing Activity instead of creating new Activities:

```typescript
// Check if Activity exists
const existing = await this.tools.plot.getActivityBySource({
  conversation_id: conversationId,
});

if (existing) {
  // Add to existing Activity
  await this.tools.plot.createNote({
    activity: { id: existing.id },
    note: newMessage.text,
  });
} else {
  // Create new Activity with initial Note
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "New conversation",
    meta: { conversation_id: conversationId },
    notes: [{ note: newMessage.text }],
  });
}
```

See [Core Concepts - Best Practices](CORE_CONCEPTS.md#best-practices-for-activities-and-notes) for more details.

## Need Help?

- **Documentation**: Continue reading the guides
- **Examples**: Check the [examples directory](https://github.com/plotday/plot/tree/main/twists)
- **Issues**: [Report bugs or request features](https://github.com/plotday/plot/issues)
