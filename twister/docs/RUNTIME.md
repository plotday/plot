---
title: Runtime Environment
group: Guides
---

# Runtime Environment

Understanding the Plot runtime environment will help you build efficient, reliable twists.

## Table of Contents

- [Execution Model](#execution-model)
- [Limitations](#limitations)
- [State Management](#state-management)
- [Batching Long Operations](#batching-long-operations)
- [Memory Considerations](#memory-considerations)
- [Performance Optimization](#performance-optimization)
- [Timeout Handling](#timeout-handling)

---

## Execution Model

Plot twists run in a **sandboxed, serverless environment** with the following characteristics:

### Ephemeral Execution

- Each method invocation runs in isolation
- No shared state between invocations
- Instance variables don't persist between calls
- Resources are cleaned up after execution

### Event-Driven

Twists respond to events:

- **Lifecycle events** - activate, upgrade, deactivate
- **Activity events** - New or updated activities
- **Webhook events** - External service notifications
- **Scheduled events** - Tasks queued with runTask()

### Resource Limits

Each execution has:

- **CPU time limit** - Limited execution time
- **Memory limit** - Limited memory allocation
- **Network limit** - Rate-limited external requests

---

## Limitations

### 1. No Persistent Instance State

Instance variables don't survive between invocations:

```typescript
// ❌ WRONG - This doesn't work!
class MyTwist extends Twist<MyTwist> {
  private syncToken: string = "";  // Lost after execution!

  async activate() {
    this.syncToken = "abc123";  // Saved to instance
  }

  async someMethod() {
    console.log(this.syncToken);  // Undefined! Different execution context
  }
}

// ✅ CORRECT - Use Store
class MyTwist extends Twist<MyTwist> {
  async activate() {
    await this.set("sync_token", "abc123");  // Persisted
  }

  async someMethod() {
    const token = await this.get<string>("sync_token");  // Retrieved
    console.log(token);  // "abc123"
  }
}
```

### 2. Limited Execution Time

Long-running operations must be broken into batches:

```typescript
// ❌ WRONG - May timeout!
async syncAllEvents() {
  const events = await fetchAllEvents();  // Could be thousands
  for (const event of events) {
    await this.processEvent(event);  // Too slow!
  }
}

// ✅ CORRECT - Batch processing
async startSync() {
  await this.set("sync_state", { page: 1, total: 0 });
  const callback = await this.callback("syncBatch");
  await this.runTask(callback);
}

async syncBatch() {
  const state = await this.get<{ page: number; total: number }>("sync_state");
  if (!state) return;

  // Process one page
  const events = await fetchEventsPage(state.page);
  await this.processEvents(events);

  // Queue next batch if needed
  if (events.hasMore) {
    await this.set("sync_state", {
      page: state.page + 1,
      total: state.total + events.length
    });

    const callback = await this.callback("syncBatch");
    await this.runTask(callback);
  }
}
```

### 3. No File System Access

Cannot read or write files:

```typescript
// ❌ WRONG - No file system
import fs from "fs";

fs.writeFileSync("data.json", JSON.stringify(data));

// ✅ CORRECT - Use Store
await this.set("data", data);
```

### 4. Limited Global State

Don't rely on global variables:

```typescript
// ❌ WRONG - Globals don't persist
let globalCache: Map<string, any> = new Map();

// ✅ CORRECT - Use Store with prefixed keys
await this.set("cache:key1", value1);
await this.set("cache:key2", value2);
```

---

## State Management

### Store Tool

The Store tool provides persistent key-value storage:

```typescript
// Save state
await this.set("key", value);

// Retrieve state
const value = await this.get<Type>("key");

// Clear state
await this.clear("key");
await this.clearAll();
```

### State Organization

Use prefixes to organize related data:

```typescript
// Configuration
await this.set("config:api_key", apiKey);
await this.set("config:workspace_id", workspaceId);

// Sync state
await this.set("sync:last_run", new Date().toISOString());
await this.set("sync:page_token", pageToken);

// Cache
await this.set("cache:user:123", userData);
await this.set("cache:repo:456", repoData);
```

### State Cleanup

Clean up state in deactivate:

```typescript
async deactivate() {
  // Option 1: Clear all
  await this.clearAll();

  // Option 2: Clear specific keys
  await this.clear("sync:page_token");
  await this.clear("cache:user:123");

  // Option 3: Clear by prefix (manually)
  // Store doesn't have native prefix clearing,
  // so track keys if needed
}
```

---

## Batching Long Operations

Break long operations into smaller batches to avoid timeouts.

### Pattern 1: Page-Based Batching

For paginated APIs:

```typescript
async startSync() {
  await this.set("sync_state", {
    page: 1,
    totalProcessed: 0,
    startTime: new Date().toISOString()
  });

  const callback = await this.callback("syncPage");
  await this.runTask(callback);
}

async syncPage() {
  const state = await this.get<SyncState>("sync_state");
  if (!state) return;

  try {
    // Fetch one page
    const response = await fetch(
      `https://api.example.com/items?page=${state.page}&per_page=50`
    );
    const data = await response.json();

    // Process items
    for (const item of data.items) {
      await this.processItem(item);
    }

    // Update state
    const newState = {
      page: state.page + 1,
      totalProcessed: state.totalProcessed + data.items.length,
      startTime: state.startTime
    };

    // Queue next page if more exist
    if (data.hasMore) {
      await this.set("sync_state", newState);
      const callback = await this.callback("syncPage");
      await this.runTask(callback);
    } else {
      // Sync complete
      console.log(`Sync complete: ${newState.totalProcessed} items`);
      await this.clear("sync_state");
    }
  } catch (error) {
    console.error("Sync error:", error);
    // Could implement retry logic here
  }
}
```

### Pattern 2: Token-Based Batching

For APIs using continuation tokens:

```typescript
interface SyncState {
  nextToken: string | null;
  totalProcessed: number;
}

async startSync() {
  await this.set<SyncState>("sync_state", {
    nextToken: null,
    totalProcessed: 0
  });

  const callback = await this.callback("syncBatch");
  await this.runTask(callback);
}

async syncBatch() {
  const state = await this.get<SyncState>("sync_state");
  if (!state) return;

  const response = await fetch(
    `https://api.example.com/items${state.nextToken ? `?token=${state.nextToken}` : ""}`
  );
  const data = await response.json();

  // Process batch
  for (const item of data.items) {
    await this.processItem(item);
  }

  // Update state and continue if needed
  if (data.nextToken) {
    await this.set<SyncState>("sync_state", {
      nextToken: data.nextToken,
      totalProcessed: state.totalProcessed + data.items.length
    });

    const callback = await this.callback("syncBatch");
    await this.runTask(callback);
  } else {
    console.log(`Complete: ${state.totalProcessed + data.items.length} items`);
    await this.clear("sync_state");
  }
}
```

### Pattern 3: Item-Based Batching

For processing arrays of items:

```typescript
async processLargeArray(items: Item[]) {
  // Save items and start processing
  await this.set("items_to_process", items);
  await this.set("process_index", 0);

  const callback = await this.callback("processBatch");
  await this.runTask(callback);
}

async processBatch() {
  const items = await this.get<Item[]>("items_to_process");
  const index = await this.get<number>("process_index");

  if (!items || index === null || index >= items.length) {
    await this.clear("items_to_process");
    await this.clear("process_index");
    return;
  }

  // Process batch of 10 items
  const batchSize = 10;
  const batch = items.slice(index, index + batchSize);

  for (const item of batch) {
    await this.processItem(item);
  }

  // Update index and continue
  const newIndex = index + batchSize;
  if (newIndex < items.length) {
    await this.set("process_index", newIndex);
    const callback = await this.callback("processBatch");
    await this.runTask(callback);
  } else {
    // Complete
    await this.clear("items_to_process");
    await this.clear("process_index");
  }
}
```

---

## Memory Considerations

### Avoid Large Data Structures

Don't load large datasets into memory:

```typescript
// ❌ WRONG - Loads everything into memory
async syncAll() {
  const allEvents = await fetchAllEvents();  // Could be 10,000+ events
  for (const event of allEvents) {
    await this.processEvent(event);
  }
}

// ✅ CORRECT - Stream/batch processing
async syncBatch() {
  const page = await this.get<number>("current_page") || 1;
  const events = await fetchEventsPage(page, 50);  // Only 50 at a time

  for (const event of events) {
    await this.processEvent(event);
  }

  // Continue with next batch
}
```

### Efficient Data Storage

Store only what's needed:

```typescript
// ❌ WRONG - Storing full response
const response = await fetch("https://api.example.com/users/123");
const fullData = await response.json();
await this.set("user_data", fullData);  // Lots of unnecessary data

// ✅ CORRECT - Store only what's needed
const response = await fetch("https://api.example.com/users/123");
const data = await response.json();
await this.set("user_name", data.name);
await this.set("user_email", data.email);
```

---

## Performance Optimization

### 1. Minimize API Calls

Batch operations where possible:

```typescript
// ❌ SLOW - Multiple round trips
for (const item of items) {
  await this.tools.plot.createActivity({
    type: ActivityType.Action,
    title: item.title,
    notes: [{ content: item.description }],
  });
}

// ✅ FAST - Batch create (always include initial notes)
// Note: Store UUID mappings separately for tracking
await this.tools.plot.createActivities(
  items.map((item) => ({
    id: Uuid.Generate(),
    type: ActivityType.Action,
    title: item.title,
    notes: [{ id: Uuid.Generate(), content: item.description }],
  }))
);
```

### 2. Parallel Operations

Run independent operations in parallel:

```typescript
// ❌ SLOW - Sequential
const user = await fetchUser();
const repos = await fetchRepos();
const issues = await fetchIssues();

// ✅ FAST - Parallel
const [user, repos, issues] = await Promise.all([
  fetchUser(),
  fetchRepos(),
  fetchIssues()
]);
```

### 3. Caching

Cache frequently accessed data:

```typescript
async getUserData(userId: string): Promise<UserData> {
  // Check cache first
  const cached = await this.get<UserData>(`cache:user:${userId}`);
  if (cached) {
    return cached;
  }

  // Fetch and cache
  const data = await fetch(`https://api.example.com/users/${userId}`);
  const userData = await data.json();

  await this.set(`cache:user:${userId}`, userData);
  return userData;
}
```

### 4. Debouncing

Avoid processing duplicate events:

```typescript
async onWebhook(request: WebhookRequest) {
  const eventId = request.body.id;

  // Check if already processed
  const processed = await this.get<boolean>(`processed:${eventId}`);
  if (processed) {
    console.log("Event already processed");
    return;
  }

  // Process and mark as done
  await this.processEvent(request.body);
  await this.set(`processed:${eventId}`, true);
}
```

---

## Timeout Handling

### Detecting Timeouts

Timeouts manifest as execution termination - your code simply stops running.

### Prevention Strategies

1. **Batch Operations** - Break work into smaller chunks
2. **Async Processing** - Use runTask() for background work
3. **Monitor Duration** - Track execution time

```typescript
async longOperation() {
  const start = Date.now();
  const items = await fetchItems();

  for (const item of items) {
    // Check if approaching timeout
    if (Date.now() - start > 55000) {  // 55 seconds
      // Save progress and reschedule
      await this.set("remaining_items", items.slice(items.indexOf(item)));
      const callback = await this.callback("continueOperation");
      await this.runTask(callback);
      return;
    }

    await this.processItem(item);
  }
}
```

---

## Best Practices Summary

1. **Never use instance variables** for persistent state - use Store
2. **Break long operations** into batches using runTask()
3. **Minimize memory usage** - don't load large datasets
4. **Cache wisely** - balance performance and memory
5. **Process in parallel** when operations are independent
6. **Track progress** for resumable operations
7. **Clean up state** in deactivate()

---

## Next Steps

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Learn about Store and Tasks tools
- **[Core Concepts](CORE_CONCEPTS.md)** - Understanding the twist architecture
