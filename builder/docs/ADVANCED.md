---
title: Advanced
group: Guides
---

# Advanced Topics

Advanced patterns and techniques for building sophisticated Plot agents.

## Table of Contents

- [Complex Agent Architectures](#complex-agent-architectures)
- [Error Handling](#error-handling)
- [Debugging and Logging](#debugging-and-logging)
- [Security Best Practices](#security-best-practices)
- [Migration and Versioning](#migration-and-versioning)
- [Performance Patterns](#performance-patterns)

---

## Complex Agent Architectures

### Multi-Service Integration

Coordinate multiple external services:

```typescript
import { GitHubTool } from "@mycompany/plot-github-tool";
import { JiraTool } from "@mycompany/plot-jira-tool";
import { SlackTool } from "@mycompany/plot-slack-tool";

import { Agent, type Priority, type ToolBuilder } from "@plotday/agent";
import { Plot } from "@plotday/agent/tools/plot";

export default class DevOpsAgent extends Agent<DevOpsAgent> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      github: build(GitHubTool, {
        owner: "mycompany",
        repo: "myapp",
        token: process.env.GITHUB_TOKEN!,
      }),
      slack: build(SlackTool, {
        webhookUrl: process.env.SLACK_WEBHOOK_URL!,
      }),
      jira: build(JiraTool, {
        domain: "mycompany.atlassian.net",
        apiToken: process.env.JIRA_TOKEN!,
      }),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    // Set up cross-service workflow
    await this.setupIssueSync();
  }

  async setupIssueSync() {
    // When GitHub issue is created, create Jira ticket and post to Slack
    // When Jira ticket is updated, update GitHub issue
    // When PR is merged, update both and notify Slack
  }
}
```

### State Machine Pattern

Implement complex workflows with state machines:

```typescript
type WorkflowState = "pending" | "in_progress" | "review" | "complete";

interface WorkflowData {
  state: WorkflowState;
  activityId: string;
  metadata: Record<string, any>;
}

class WorkflowAgent extends Agent<WorkflowAgent> {
  async transitionTo(workflowId: string, newState: WorkflowState) {
    const workflow = await this.get<WorkflowData>(`workflow:${workflowId}`);
    if (!workflow) throw new Error("Workflow not found");

    const oldState = workflow.state;

    // Validate transition
    if (!this.isValidTransition(oldState, newState)) {
      throw new Error(`Invalid transition: ${oldState} -> ${newState}`);
    }

    // Execute transition logic
    await this.onExit(workflowId, oldState);

    workflow.state = newState;
    await this.set(`workflow:${workflowId}`, workflow);

    await this.onEnter(workflowId, newState);
  }

  private isValidTransition(from: WorkflowState, to: WorkflowState): boolean {
    const transitions: Record<WorkflowState, WorkflowState[]> = {
      pending: ["in_progress"],
      in_progress: ["review", "pending"],
      review: ["complete", "in_progress"],
      complete: [],
    };

    return transitions[from]?.includes(to) ?? false;
  }

  private async onEnter(workflowId: string, state: WorkflowState) {
    switch (state) {
      case "in_progress":
        await this.notifyAssigned(workflowId);
        break;
      case "review":
        await this.requestReview(workflowId);
        break;
      case "complete":
        await this.markComplete(workflowId);
        break;
    }
  }

  private async onExit(workflowId: string, state: WorkflowState) {
    // Cleanup for previous state
  }
}
```

---

## Error Handling

### Graceful Degradation

Handle errors without breaking the agent:

```typescript
async activate(priority: Pick<Priority, "id">) {
  try {
    await this.setupWebhooks();
  } catch (error) {
    console.error("Failed to setup webhooks:", error);
    // Agent still activates, just without webhooks
    // Consider creating an activity to notify the user
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "⚠️ Webhook setup failed",
      note: `Could not set up automatic syncing. Error: ${error.message}`
    });
  }

  // Continue with other initialization
  await this.initialSync();
}
```

### Retry Logic

Implement exponential backoff for transient failures:

```typescript
async fetchWithRetry<T>(
  url: string,
  maxRetries: number = 3
): Promise<T> {
  let lastError: Error;

  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const response = await fetch(url);

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      return await response.json();
    } catch (error) {
      lastError = error as Error;
      console.error(`Attempt ${attempt + 1} failed:`, error);

      if (attempt < maxRetries - 1) {
        // Exponential backoff: 1s, 2s, 4s
        const delay = Math.pow(2, attempt) * 1000;
        await new Promise(resolve => setTimeout(resolve, delay));
      }
    }
  }

  throw new Error(`Failed after ${maxRetries} attempts: ${lastError!.message}`);
}
```

### Error Recovery

Save state before risky operations:

```typescript
async processLargeDataset(items: Item[]) {
  for (let i = 0; i < items.length; i++) {
    try {
      await this.processItem(items[i]);

      // Save progress
      await this.set("last_processed_index", i);
    } catch (error) {
      console.error(`Error processing item ${i}:`, error);

      // Create activity for manual review
      await this.tools.plot.createActivity({
        type: ActivityType.Note,
        title: `Processing error at item ${i}`,
        note: error.message
      });

      // Continue with next item
      continue;
    }
  }
}

// Resume from last checkpoint
async resumeProcessing() {
  const lastIndex = await this.get<number>("last_processed_index") || 0;
  const items = await this.get<Item[]>("items_to_process");

  if (items) {
    await this.processLargeDataset(items.slice(lastIndex + 1));
  }
}
```

---

## Debugging and Logging

### Structured Logging

Use consistent log formats:

```typescript
interface LogContext {
  agentId: string;
  priorityId?: string;
  operation: string;
  [key: string]: any;
}

class MyAgent extends Agent<MyAgent> {
  private log(
    level: "info" | "warn" | "error",
    message: string,
    context?: Partial<LogContext>
  ) {
    const logEntry = {
      timestamp: new Date().toISOString(),
      level,
      message,
      agent: this.id,
      ...context,
    };

    console.log(JSON.stringify(logEntry));
  }

  async activate(priority: Pick<Priority, "id">) {
    this.log("info", "Agent activating", {
      priorityId: priority.id,
      operation: "activate",
    });

    try {
      await this.setupWebhooks();
      this.log("info", "Webhooks configured successfully");
    } catch (error) {
      this.log("error", "Failed to setup webhooks", {
        error: error.message,
        stack: error.stack,
      });
    }
  }
}
```

### Debug Mode

Add debug flag for verbose logging:

```typescript
class MyAgent extends Agent<MyAgent> {
  private get debugMode(): Promise<boolean> {
    return this.get<boolean>("debug_mode").then((v) => v ?? false);
  }

  private async debug(message: string, data?: any) {
    if (await this.debugMode) {
      console.log(`[DEBUG] ${message}`, data || "");
    }
  }

  async processData(data: any) {
    await this.debug("Processing data", { itemCount: data.length });

    for (const item of data) {
      await this.debug("Processing item", item);
      await this.processItem(item);
    }
  }
}
```

### Performance Monitoring

Track operation durations:

```typescript
async withTiming<T>(
  operation: string,
  fn: () => Promise<T>
): Promise<T> {
  const start = Date.now();

  try {
    const result = await fn();
    const duration = Date.now() - start;

    console.log(`[PERF] ${operation}: ${duration}ms`);

    return result;
  } catch (error) {
    const duration = Date.now() - start;
    console.log(`[PERF] ${operation}: ${duration}ms (failed)`);
    throw error;
  }
}

// Usage
await this.withTiming("sync-calendar", async () => {
  await this.syncCalendar();
});
```

---

## Security Best Practices

### Secrets Management

Never hardcode secrets:

```typescript
// ❌ WRONG
const apiKey = "sk-1234567890abcdef";

// ✅ CORRECT - Use environment variables
const apiKey = process.env.API_KEY;
if (!apiKey) {
  throw new Error("API_KEY environment variable is required");
}
```

### Input Validation

Validate all external input:

```typescript
async onWebhook(request: WebhookRequest) {
  // Validate signature
  if (!this.validateSignature(request)) {
    console.error("Invalid webhook signature");
    return;
  }

  // Validate schema
  if (!this.isValidPayload(request.body)) {
    console.error("Invalid webhook payload");
    return;
  }

  // Process safely
  await this.processWebhook(request.body);
}

private validateSignature(request: WebhookRequest): boolean {
  const signature = request.headers["x-webhook-signature"];
  const expectedSignature = this.computeSignature(request.body);
  return signature === expectedSignature;
}
```

### Rate Limiting

Protect external APIs:

```typescript
class RateLimiter {
  private lastRequest: number = 0;
  private minInterval: number = 1000;  // 1 request per second

  async throttle<T>(fn: () => Promise<T>): Promise<T> {
    const now = Date.now();
    const timeSinceLastRequest = now - this.lastRequest;

    if (timeSinceLastRequest < this.minInterval) {
      const delay = this.minInterval - timeSinceLastRequest;
      await new Promise(resolve => setTimeout(resolve, delay));
    }

    this.lastRequest = Date.now();
    return await fn();
  }
}

// Usage
private rateLimiter = new RateLimiter();

async fetchData() {
  return await this.rateLimiter.throttle(async () => {
    return await fetch("https://api.example.com/data");
  });
}
```

---

## Migration and Versioning

### Version Tracking

Track agent version for migrations:

```typescript
async activate(priority: Pick<Priority, "id">) {
  await this.set("agent_version", "1.0.0");
}

async upgrade() {
  const currentVersion = await this.get<string>("agent_version") || "0.0.0";

  if (this.compareVersions(currentVersion, "2.0.0") < 0) {
    await this.migrateToV2();
  }

  if (this.compareVersions(currentVersion, "2.1.0") < 0) {
    await this.migrateToV21();
  }

  await this.set("agent_version", "2.1.0");
}
```

### Data Migration

Migrate stored data structures:

```typescript
async migrateToV2() {
  // V1 stored user data as separate fields
  const userId = await this.get<string>("user_id");
  const userName = await this.get<string>("user_name");
  const userEmail = await this.get<string>("user_email");

  if (userId && userName && userEmail) {
    // V2 uses a single user object
    await this.set("user", {
      id: userId,
      name: userName,
      email: userEmail
    });

    // Clean up old fields
    await this.clear("user_id");
    await this.clear("user_name");
    await this.clear("user_email");
  }
}
```

### Breaking Changes

Handle breaking changes gracefully:

```typescript
async upgrade() {
  const version = await this.get<string>("version") || "1.0.0";

  if (version < "2.0.0") {
    // V2 completely changed how webhooks work
    // Clean up old webhooks
    const oldWebhooks = await this.get<string[]>("webhooks");
    if (oldWebhooks) {
      for (const webhook of oldWebhooks) {
        await this.deleteOldWebhook(webhook);
      }
      await this.clear("webhooks");
    }

    // Set up new webhook system
    await this.setupNewWebhooks();
  }

  await this.set("version", "2.0.0");
}
```

---

## Performance Patterns

### Lazy Loading

Load data only when needed:

```typescript
class MyAgent extends Agent<MyAgent> {
  private _config: Config | null = null;

  private async getConfig(): Promise<Config> {
    if (!this._config) {
      this._config = await this.get<Config>("config");
    }
    return this._config!;
  }

  async someMethod() {
    const config = await this.getConfig(); // Loaded once
    // Use config...
  }
}
```

### Request Coalescing

Combine multiple similar requests:

```typescript
private pendingUserFetches = new Map<string, Promise<User>>();

async getUser(userId: string): Promise<User> {
  // If already fetching, return existing promise
  if (this.pendingUserFetches.has(userId)) {
    return this.pendingUserFetches.get(userId)!;
  }

  // Start new fetch
  const promise = this.fetchUser(userId);
  this.pendingUserFetches.set(userId, promise);

  try {
    const user = await promise;
    return user;
  } finally {
    this.pendingUserFetches.delete(userId);
  }
}
```

### Bulk Operations

Batch database operations:

```typescript
async syncAllItems(items: Item[]) {
  // ❌ SLOW - One at a time
  // for (const item of items) {
  //   await this.tools.plot.createActivity({...});
  // }

  // ✅ FAST - Bulk create
  await this.tools.plot.createActivities(
    items.map(item => ({
      type: ActivityType.Task,
      title: item.title,
      note: item.description
    }))
  );
}
```

---

## Next Steps

- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints
- **[Building Tools](BUILDING_TOOLS.md)** - Creating reusable tools
- **[Built-in Tools](TOOLS_GUIDE.md)** - Comprehensive tool documentation
- **API Reference** - Explore detailed API documentation
