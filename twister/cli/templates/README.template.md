# {{displayName}} twist

A Plot twist that [describe what your twist does].

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
│   └── index.ts      # Main twist implementation
├── package.json      # twist metadata and dependencies
├── tsconfig.json     # TypeScript configuration
└── README.md         # This file
```

### twist Lifecycle

Your twist implements two key lifecycle methods:

#### `activate(priority: Pick<Priority, "id">)`

Called when the twist is enabled for a priority. This is where you typically:
- Request authentication from external services
- Create initial setup activities
- Initialize twist state

#### `activity(activity: Activity)`

Called when an activity is routed to this twist. Use this to:
- Process incoming activities
- Create new activities based on external events
- Update existing activities

### Using Tools

Twists access functionality through tools. Declare tools in the `build` method:

```typescript
build(build: ToolBuilder) {
  return {
    plot: build(Plot),
  };
}
// Store, Tasks, and Callbacks methods are available directly via this
```

#### Built-in Tools

- **Plot**: Create, update, and delete activities
- **Store**: Persist data across twist invocations
- **Integrations**: Request OAuth authentication from external services
- **Tasks**: Queue background tasks and batch operations
- **Callbacks**: Create persistent function references for webhooks
- **Network**: HTTP access permissions and webhook management

#### External Tools

Add external tool dependencies to `package.json`:

```json
{
  "dependencies": {
    "@plotday/twister": "workspace:^",
    "@plotday/tool-google-calendar": "workspace:^"
  }
}
```

Then use them in your twist:

```typescript
import GoogleCalendarTool from "@plotday/tool-google-calendar";

build(build: ToolBuilder) {
  return {
    googleCalendar: build(GoogleCalendarTool),
  };
}
```

### Activity Types

Plot supports three activity types:

- **ActivityType.Note**: Information without actionable requirements
- **ActivityType.Task**: Actionable items that can be completed
- **ActivityType.Event**: Scheduled occurrences with start/end times

### State Management

Use Store methods (available directly on twist and Tool classes) to persist data across twist invocations:

```typescript
// Save state
await this.set("sync_token", token);

// Load state
const token = await this.get<string>("sync_token");
```

**Important**: twist instances are ephemeral. Always use Store methods for data that needs to persist.

### Runtime Limitations

**Important**: All twist and tool functions are executed in a sandboxed, ephemeral environment with limited resources:

- **Memory is temporary**: Anything stored in memory (e.g. as a variable in the twist/tool object) is lost after the function completes. Use the Store tool instead. Only use memory for temporary caching.
- **Limited CPU time**: Each execution has limited CPU time (typically 10 seconds) and memory (128MB)
- **Use the Tasks tool**: Queue separate chunks of work with `this.run(callback)`
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

Test your twist locally before deploying:

```bash
# Run linter
{{packageManager}} lint

# Deploy to your Plot account
{{packageManager}} deploy
```

## Resources

- [Plot twist Builder Documentation](https://github.com/plotday/plot)
- [twist Examples](https://github.com/plotday/plot/tree/main/libs/twist/examples)
- [Tool Documentation](https://github.com/plotday/plot/tree/main/libs/twist/tools)

## Support

For help or questions:
- Open an issue on GitHub
- Contact support@plot.day
