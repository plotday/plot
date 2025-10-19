# {{displayName}} Agent

A Plot agent that [describe what your agent does].

## Quick Start

```bash
# Install dependencies
{{packageManager}} install

# Lint your code
{{packageManager}} lint

# Deploy to Plot
{{packageManager}} deploy
```

## Development

### Project Structure

```
.
├── src/
│   └── index.ts      # Main agent implementation
├── package.json      # Agent metadata and dependencies
├── tsconfig.json     # TypeScript configuration
└── README.md         # This file
```

### Agent Lifecycle

Your agent implements two key lifecycle methods:

#### `activate(priority: Pick<Priority, "id">)`

Called when the agent is enabled for a priority. This is where you typically:
- Request authentication from external services
- Create initial setup activities
- Initialize agent state

#### `activity(activity: Activity)`

Called when an activity is routed to this agent. Use this to:
- Process incoming activities
- Create new activities based on external events
- Update existing activities

### Using Tools

Agents access functionality through tools. Get tools in the constructor:

```typescript
constructor(protected tools: Tools) {
  super(id, tools);
  this.plot = tools.get(Plot);
  // Store, Run, and Callback methods are available directly via this
}
```

#### Built-in Tools

- **Plot**: Create, update, and delete activities
- **Store**: Persist data across agent invocations
- **Auth**: Request OAuth authentication from external services
- **Run**: Queue background tasks and batch operations
- **Callback**: Create persistent function references for webhooks

#### External Tools

Add external tool dependencies to `package.json`:

```json
{
  "dependencies": {
    "@plotday/sdk": "workspace:^",
    "@plotday/tool-google-calendar": "workspace:^"
  }
}
```

Then use them in your agent:

```typescript
import { GoogleCalendar } from "@plotday/sdk/tools/google-calendar";

constructor(id: string, tools: Tools) {
  super();
  this.googleCalendar = tools.get(GoogleCalendar);
}
```

### Activity Types

Plot supports three activity types:

- **ActivityType.Note**: Information without actionable requirements
- **ActivityType.Task**: Actionable items that can be completed
- **ActivityType.Event**: Scheduled occurrences with start/end times

### State Management

Use Store methods (available directly on Agent and Tool classes) to persist data across agent invocations:

```typescript
// Save state
await this.set("sync_token", token);

// Load state
const token = await this.get<string>("sync_token");
```

**Important**: Agent instances are ephemeral. Always use Store methods for data that needs to persist.

### Runtime Limitations

**Important**: All agent and tool functions are executed in a sandboxed, ephemeral environment with limited resources:

- **Memory is temporary**: Anything stored in memory (e.g. as a variable in the agent/tool object) is lost after the function completes. Use the Store tool instead. Only use memory for temporary caching.
- **Limited CPU time**: Each execution has limited CPU time (typically 10 seconds) and memory (128MB)
- **Use the Run tool**: Queue separate chunks of work with `run.now(functionName, context)`
- **Break long operations**: Split large operations into smaller batches that can be processed independently
- **Store intermediate state**: Use the Store tool to persist state between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

#### Pattern for Long-Running Operations

```typescript
async startSync(calendarId: string): Promise<void> {
  // Initialize state in Store (persists between executions)
  await this.set(`sync_state_${calendarId}`, {
    nextPageToken: null,
    batchNumber: 1,
  });

  // Queue first batch using run method
  const callback = await this.callback("syncBatch", { calendarId });
  await this.run(callback);
}

async syncBatch(args: any, context: { calendarId: string }): Promise<void> {
  // Load state from Store
  const state = await this.get(`sync_state_${calendarId}`);

  // Process one batch
  const result = await processBatch(state.nextPageToken);

  if (result.hasMore) {
    // Update state and queue next batch
    await this.set(`sync_state_${context.calendarId}`, {
      nextPageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
    });

    const nextCallback = await this.callback("syncBatch", context);
    await this.run(nextCallback);
  } else {
    // Cleanup when done
    await this.clear(`sync_state_${context.calendarId}`);
  }
}
```

## Testing

Test your agent locally before deploying:

```bash
# Run linter
{{packageManager}} lint

# Deploy to your Plot account
{{packageManager}} deploy
```

## Resources

- [Plot SDK Documentation](https://github.com/plotday/plot)
- [Agent Examples](https://github.com/plotday/plot/tree/main/libs/agent/examples)
- [Tool Documentation](https://github.com/plotday/plot/tree/main/libs/agent/tools)

## Support

For help or questions:
- Open an issue on GitHub
- Contact support@plot.day
