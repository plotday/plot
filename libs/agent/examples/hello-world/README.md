# Hello World Agent

A minimal Plot agent that demonstrates the basic structure and lifecycle.

## What it does

When activated for a priority, this agent creates a welcome activity with a friendly message.

## Code

```typescript
import {
  type Activity,
  ActivityType,
  Agent,
  type Priority,
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

    async activate(priority: Pick<Priority, "id">) {
      // Create a welcome activity when the agent is activated
      await this.plot.createActivity({
        type: ActivityType.Note,
        title: "👋 Welcome to Plot!",
        note: "Your Hello World agent is now active and ready to help.",
      });
    }

    async activity(activity: Activity) {
      // This agent doesn't process activities, but you could add logic here
      console.log("Received activity:", activity.title);
    }
  }
);
```

## Key Concepts

### 1. Agent Structure

Every agent extends the `Agent` base class and implements lifecycle methods:
- `activate()` - Called when the agent is enabled for a priority
- `activity()` - Called when an activity is routed to the agent

### 2. Tools

Agents access functionality through tools. The `Plot` tool provides core capabilities:
- Create activities
- Update activities
- Delete activities
- Manage priorities

### 3. Activity Types

Plot supports three activity types:
- `ActivityType.Note` - Information without actionable requirements
- `ActivityType.Task` - Actionable items that can be completed
- `ActivityType.Event` - Scheduled occurrences with start/end times

## Setup

1. Create the agent:
   ```bash
   npx @plotday/sdk agent create --dir hello-world
   ```

2. Copy the code above to `src/index.ts`

3. Deploy:
   ```bash
   npm run deploy
   ```

## Next Steps

- Add logic to the `activity()` method to process incoming activities
- Create tasks or events instead of notes
- Add activity links for user interaction
- Explore other built-in tools (Store, Auth, Run, etc.)
