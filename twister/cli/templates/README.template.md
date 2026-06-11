# {{displayName}} twist

A Plot twist that [describe what your twist does].

## Quick Start

```bash
# Lint your code
{{packageManager}} lint

# Deploy to Plot
{{packageManager}} deploy
```

Dependencies are installed automatically when the project is created.

## Development

### Project Structure

```
.
├── src/
│   └── index.ts      # Main twist implementation
├── package.json      # twist metadata and dependencies
├── tsconfig.json     # TypeScript configuration
├── AGENTS.md         # Implementation guide for AI assistants
├── CLAUDE.md         # Claude Code entry point (includes AGENTS.md)
└── README.md         # This file
```

### twist Lifecycle

Your twist overrides lifecycle methods from the `Twist` base class:

#### `activate(context?: { actor: Actor })`

Called when the twist is installed by a user. Authentication and resource selection are handled automatically in the twist edit modal, so this is where you typically:
- Seed initial threads
- Initialize twist state

#### `onThreadUpdated(thread, changes)` / `onNoteCreated(note, thread)`

Called when a thread created by this twist is updated, or a note is added to one. Use these to:
- Implement two-way sync with external systems
- React to user replies and tag changes

Other hooks include `upgrade()` (new version deployed) and `deactivate()` (twist uninstalled).

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

- **Plot**: Create and update threads, notes, and focuses
- **Store**: Persist data across twist invocations
- **Integrations**: OAuth authentication and channel management for external services
- **Tasks**: Queue background tasks and batch operations
- **Callbacks**: Create persistent function references for webhooks
- **Network**: HTTP access permissions and webhook management
- **AI**: LLM text generation and structured output

#### Connectors

External service integrations (Google Calendar, Slack, Linear, etc.) are built as Connectors. See the [Building Connectors](https://twist.plot.day/documents/Building_Connectors.html) guide.

### Thread Types

A thread's `type` is an optional display sub-type: `"action"`, `"notes"`, `"idea"`, `"goal"`, `"decision"`, `"discussion"`, `"announcement"`, or `"ask"`.

- Omit it for the default (`"notes"` in private focuses, `"discussion"` in shared ones)
- Use `"action"` for tasks
- Scheduled events are threads with `schedules`

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
- **Limited requests per execution**: Each execution has ~1000 requests (HTTP requests, tool calls, database operations)
- **Limited CPU time**: Each execution has limited CPU time (typically ~60 seconds) and memory (128MB)
- **Use the Tasks tool**: Queue separate chunks of work with `this.runTask(callback)` — each task runs in a new execution with a fresh request limit
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

  // Queue first batch as a task (new execution, fresh request limit)
  const callback = await this.callback(this.syncBatch, calendarId);
  await this.runTask(callback);
}

async syncBatch(calendarId: string): Promise<void> {
  // Load state from Store
  const state = await this.get(`sync_state_${calendarId}`);

  // Process one batch
  const result = await processBatch(state.nextPageToken);

  if (result.hasMore) {
    // Update state and queue next batch
    await this.set(`sync_state_${calendarId}`, {
      nextPageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
    });

    const nextCallback = await this.callback(this.syncBatch, calendarId);
    await this.runTask(nextCallback);
  } else {
    // Cleanup when done
    await this.clear(`sync_state_${calendarId}`);
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

- [Plot Twist Creator Documentation](https://twist.plot.day)
- [Connector Examples](https://github.com/plotday/plot/tree/main/connectors)
- [Tool Type Definitions](https://github.com/plotday/plot/tree/main/twister/src/tools)

## Support

For help or questions:
- Open an issue on GitHub
- Contact support@plot.day
