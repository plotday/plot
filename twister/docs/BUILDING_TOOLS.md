---
title: Building Custom Tools
group: Guides
---

# Building Custom Tools

Custom tools let you create reusable functionality that can be shared across twists or published for others to use. This guide covers everything you need to know about building tools.

## Table of Contents

- [Why Build Tools?](#why-build-tools)
- [Tool Basics](#tool-basics)
- [Tool Structure](#tool-structure)
- [Lifecycle Methods](#lifecycle-methods)
- [Dependencies](#dependencies)
- [Options and Configuration](#options-and-configuration)
- [Complete Examples](#complete-examples)
- [Testing Tools](#testing-tools)
- [Publishing Tools](#publishing-tools)
- [Best Practices](#best-practices)

---

## Why Build Tools?

Build custom tools when you need to:

- **Integrate external services** - GitHub, Slack, Notion, etc.
- **Encapsulate complex logic** - Reusable business logic
- **Share functionality** - Between multiple twists
- **Abstract implementation details** - Clean interfaces for common operations

### Built-in vs. Custom Tools

| Built-in Tools                 | Custom Tools                         |
| ------------------------------ | ------------------------------------ |
| Plot, Store, AI, Network, etc. | Your integrations and utilities      |
| Access to Plot internals       | Built on top of built-in tools       |
| Provided by twist Builder      | Created by you or installed from npm |
| Always available               | Declared as dependencies             |

---

## Tool Basics

Tools extend the `Tool<T>` base class and can access other tools through dependencies.

### Minimal Tool Example

```typescript
import { Tool, type ToolBuilder } from "@plotday/twister";

export class HelloTool extends Tool<HelloTool> {
  async sayHello(name: string): Promise<string> {
    return `Hello, ${name}!`;
  }
}
```

### Using Your Tool

```typescript
import { twist, type ToolBuilder } from "@plotday/twister";

import { HelloTool } from "./tools/hello";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      hello: build(HelloTool),
    };
  }

  async activate() {
    const message = await this.tools.hello.sayHello("World");
    console.log(message); // "Hello, World!"
  }
}
```

---

## Tool Structure

### Class Definition

```typescript
import { Tool, type ToolBuilder } from "@plotday/twister";

// Tool class with type parameter
export class MyTool extends Tool<MyTool> {
  // Constructor receives id, options, and toolShed
  constructor(id: string, options: InferOptions<MyTool>, toolShed: ToolShed) {
    super(id, options, toolShed);
  }

  // Public methods
  async myMethod(): Promise<void> {
    // Implementation
  }
}
```

### Type Parameter

The type parameter `<MyTool>` enables:

- Type-safe options inference
- Type-safe tool dependencies
- Proper TypeScript autocomplete

---

## Lifecycle Methods

Tools have lifecycle methods that run at specific times during the twist lifecycle.

### preActivate(priority)

Called **before** the twist's `activate()` method, depth-first.

```typescript
async preActivate(priority: Priority): Promise<void> {
  // Setup that needs to happen before twist activation
  console.log("Tool preparing for activation");

  // Initialize connections, validate configuration, etc.
}
```

**Use for:**

- Validating configuration
- Setting up connections
- Preparing resources

### postActivate(priority)

Called **after** the twist's `activate()` method, reverse order.

```typescript
async postActivate(priority: Priority): Promise<void> {
  // Finalization after twist is activated
  console.log("Tool finalizing activation");

  // Start background processes, register webhooks, etc.
}
```

**Use for:**

- Starting background processes
- Registering webhooks
- Final initialization

### preUpgrade()

Called **before** the twist's `upgrade()` method.

```typescript
async preUpgrade(): Promise<void> {
  // Prepare for upgrade
  const version = await this.get<string>("tool_version");

  if (version === "1.0.0") {
    // Migrate data
  }
}
```

### postUpgrade()

Called **after** the twist's `upgrade()` method.

```typescript
async postUpgrade(): Promise<void> {
  // Finalize upgrade
  await this.set("tool_version", "2.0.0");
}
```

### preDeactivate()

Called **before** the twist's `deactivate()` method.

```typescript
async preDeactivate(): Promise<void> {
  // Cleanup before deactivation
  await this.stopBackgroundProcesses();
}
```

### postDeactivate()

Called **after** the twist's `deactivate()` method.

```typescript
async postDeactivate(): Promise<void> {
  // Final cleanup
  await this.clearAll();
}
```

### Execution Order

```
twist Activation:
  1. Tool.preActivate() (deepest dependencies first)
  2. twist.activate()
  3. Tool.postActivate() (top-level tools first)

twist Deactivation:
  1. Tool.preDeactivate() (deepest dependencies first)
  2. twist.deactivate()
  3. Tool.postDeactivate() (top-level tools first)
```

---

## Dependencies

Tools can depend on other tools, including built-in tools.

### Declaring Dependencies

```typescript
import { Tool, type ToolBuilder } from "@plotday/twister";
import { Network } from "@plotday/twister/tools/network";
import { Store } from "@plotday/twister/tools/store";

export class GitHubTool extends Tool<GitHubTool> {
  // Declare dependencies
  build(build: ToolBuilder) {
    return {
      network: build(Network, {
        urls: ["https://api.github.com/*"],
      }),
      store: build(Store),
    };
  }

  // Access dependencies
  async getRepository(owner: string, repo: string) {
    const response = await fetch(
      `https://api.github.com/repos/${owner}/${repo}`
    );
    return await response.json();
  }
}
```

### Accessing Dependencies

Use `this.tools` to access declared dependencies:

```typescript
async fetchData() {
  // Tools are fully typed
  const data = await this.tools.network.fetch("https://api.example.com/data");
  await this.tools.store.set("cached_data", data);
}
```

### Built-in Tool Access

Tools have direct access to Store, Tasks, and Callbacks methods:

```typescript
export class MyTool extends Tool<MyTool> {
  async doWork() {
    // Store
    await this.set("key", "value");
    const value = await this.get<string>("key");

    // Tasks
    const callback = await this.callback("processData");
    await this.runTask(callback);

    // Callbacks
    await this.deleteCallback(callback);
  }
}
```

---

## Options and Configuration

Tools can accept configuration options when declared.

### Defining Options

```typescript
import { Tool, type ToolBuilder, type InferOptions } from "@plotday/twister";

export class SlackTool extends Tool<SlackTool> {
  // Define static Options type
  static Options = {
    workspaceId: "" as string,
    defaultChannel?: "" as string | undefined,
  };

  // Access via this.options
  async postMessage(message: string, channel?: string) {
    const targetChannel = channel || this.options.defaultChannel;

    if (!targetChannel) {
      throw new Error("No channel specified");
    }

    console.log(`Posting to ${targetChannel} in ${this.options.workspaceId}`);
    // Post message...
  }
}
```

### Using Options

```typescript
build(build: ToolBuilder) {
  return {
    slack: build(SlackTool, {
      workspaceId: "T1234567",
      defaultChannel: "#general"
    }),
  };
}
```

### Required vs. Optional Options

```typescript
static Options = {
  // Required - no default value, not undefined
  apiKey: "" as string,
  workspaceId: "" as string,

  // Optional - has undefined as possible value
  defaultChannel?: "" as string | undefined,
  timeout?: 0 as number | undefined,

  // Optional with default
  retryCount: 3 as number,
};
```

---

## Complete Examples

### Example 1: GitHub Integration Tool

A complete GitHub integration with webhooks and issue management.

```typescript
import { type Priority, Tool, type ToolBuilder } from "@plotday/twister";
import { ActivityLinkType, ActivityType } from "@plotday/twister";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Plot } from "@plotday/twister/tools/plot";

export class GitHubTool extends Tool<GitHubTool> {
  static Options = {
    owner: "" as string,
    repo: "" as string,
    token: "" as string,
  };

  build(build: ToolBuilder) {
    return {
      network: build(Network, {
        urls: ["https://api.github.com/*"],
      }),
      plot: build(Plot),
    };
  }

  async postActivate(priority: Priority): Promise<void> {
    // Set up webhook for issue updates
    const webhookUrl = await this.tools.network.createWebhook("onIssueUpdate", {
      priorityId: priority.id,
    });

    await this.set("webhook_url", webhookUrl);

    // Register webhook with GitHub
    await this.registerWebhook(webhookUrl);
  }

  async preDeactivate(): Promise<void> {
    // Cleanup webhook
    const webhookUrl = await this.get<string>("webhook_url");
    if (webhookUrl) {
      await this.unregisterWebhook(webhookUrl);
      await this.tools.network.deleteWebhook(webhookUrl);
    }
  }

  async getIssues(): Promise<any[]> {
    const response = await fetch(
      `https://api.github.com/repos/${this.options.owner}/${this.options.repo}/issues`,
      {
        headers: {
          Authorization: `Bearer ${this.options.token}`,
          Accept: "application/vnd.github.v3+json",
        },
      }
    );

    return await response.json();
  }

  async syncIssues(): Promise<void> {
    const issues = await this.getIssues();

    for (const issue of issues) {
      await this.tools.plot.createActivity({
        type: ActivityType.Action,
        title: issue.title,
        note: issue.body,
        meta: {
          github_issue_id: issue.id.toString(),
          github_number: issue.number.toString(),
        },
        links: [
          {
            type: ActivityLinkType.external,
            title: "View on GitHub",
            url: issue.html_url,
          },
        ],
      });
    }
  }

  async onIssueUpdate(
    request: WebhookRequest,
    context: { priorityId: string }
  ): Promise<void> {
    const { action, issue } = request.body;

    if (action === "opened") {
      // Create new activity for new issue
      await this.tools.plot.createActivity({
        type: ActivityType.Action,
        title: issue.title,
        meta: {
          github_issue_id: issue.id.toString(),
        },
      });
    } else if (action === "closed") {
      // Mark activity as done
      const activity = await this.tools.plot.getActivityByMeta({
        github_issue_id: issue.id.toString(),
      });

      if (activity) {
        await this.tools.plot.updateActivity(activity.id, {
          doneAt: new Date(),
        });
      }
    }
  }

  private async registerWebhook(url: string): Promise<void> {
    await fetch(
      `https://api.github.com/repos/${this.options.owner}/${this.options.repo}/hooks`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.options.token}`,
          Accept: "application/vnd.github.v3+json",
        },
        body: JSON.stringify({
          config: { url, content_type: "json" },
          events: ["issues"],
        }),
      }
    );
  }

  private async unregisterWebhook(url: string): Promise<void> {
    // Implementation to remove webhook from GitHub
  }
}
```

### Example 2: Slack Notification Tool

A tool for sending Slack notifications.

```typescript
import { Tool, type ToolBuilder } from "@plotday/twister";
import { Network } from "@plotday/twister/tools/network";

export class SlackTool extends Tool<SlackTool> {
  static Options = {
    webhookUrl: "" as string,
    defaultChannel?: "" as string | undefined,
  };

  build(build: ToolBuilder) {
    return {
      network: build(Network, {
        urls: ["https://hooks.slack.com/*"]
      }),
    };
  }

  async sendMessage(options: {
    text: string;
    channel?: string;
    username?: string;
  }): Promise<void> {
    const payload = {
      text: options.text,
      channel: options.channel || this.options.defaultChannel,
      username: options.username || "Plot Bot"
    };

    const response = await fetch(this.options.webhookUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      throw new Error(`Slack API error: ${response.statusText}`);
    }
  }

  async sendAlert(message: string): Promise<void> {
    await this.sendMessage({
      text: `:warning: ${message}`,
      channel: "#alerts"
    });
  }
}
```

---

## Testing Tools

### Unit Testing

```typescript
import { beforeEach, describe, expect, it } from "vitest";

import { GitHubTool } from "./github-tool";

describe("GitHubTool", () => {
  let tool: GitHubTool;

  beforeEach(() => {
    tool = new GitHubTool(
      "test-id",
      {
        owner: "test-owner",
        repo: "test-repo",
        token: "test-token",
      },
      mockToolShed
    );
  });

  it("fetches issues", async () => {
    const issues = await tool.getIssues();
    expect(issues).toBeInstanceOf(Array);
  });

  it("validates configuration", () => {
    expect(tool.options.owner).toBe("test-owner");
    expect(tool.options.repo).toBe("test-repo");
  });
});
```

### Integration Testing

Test your tool with a real twist:

```typescript
import { twist, type ToolBuilder } from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

import { GitHubTool } from "./github-tool";

class TestTwist extends Twist<TestTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      github: build(GitHubTool, {
        owner: "plotday",
        repo: "plot",
        token: process.env.GITHUB_TOKEN!,
      }),
    };
  }

  async activate() {
    // Test syncing
    await this.tools.github.syncIssues();
  }
}
```

---

## Publishing Tools

### Package Structure

```
my-plot-tool/
├── src/
│   └── index.ts          # Tool implementation
├── package.json
├── tsconfig.json
├── README.md
└── LICENSE
```

### package.json

```json
{
  "name": "@mycompany/plot-github-tool",
  "version": "1.0.0",
  "description": "GitHub integration tool for Plot twists",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "test": "vitest"
  },
  "peerDependencies": {
    "@plotday/twister": "^0.16.0"
  },
  "devDependencies": {
    "@plotday/twister": "^0.16.0",
    "typescript": "^5.0.0"
  }
}
```

### Publishing

```bash
# Build
npm run build

# Test
npm test

# Publish
npm publish
```

### Documentation

Include comprehensive README with:

- Installation instructions
- Configuration options
- Usage examples
- API reference

---

## Best Practices

### 1. Single Responsibility

Each tool should have a single, well-defined purpose:

```typescript
// ✅ GOOD - Focused on GitHub
class GitHubTool extends Tool<GitHubTool> {
  async getIssues() {
    /* ... */
  }
  async createIssue() {
    /* ... */
  }
}

// ❌ BAD - Mixed concerns
class IntegrationTool extends Tool<IntegrationTool> {
  async getGitHubIssues() {
    /* ... */
  }
  async sendSlackMessage() {
    /* ... */
  }
  async createJiraTicket() {
    /* ... */
  }
}
```

### 2. Type Safety

Use TypeScript features for type safety:

```typescript
export interface GitHubIssue {
  id: number;
  title: string;
  body: string;
  state: "open" | "closed";
}

export class GitHubTool extends Tool<GitHubTool> {
  async getIssues(): Promise<GitHubIssue[]> {
    // Return type is enforced
  }
}
```

### 3. Error Handling

Handle errors gracefully:

```typescript
async fetchData(): Promise<Data | null> {
  try {
    const response = await fetch(this.apiUrl);

    if (!response.ok) {
      console.error(`API error: ${response.status}`);
      return null;
    }

    return await response.json();
  } catch (error) {
    console.error("Network error:", error);
    return null;
  }
}
```

### 4. Configuration Validation

Validate options in preActivate:

```typescript
async preActivate(priority: Priority): Promise<void> {
  if (!this.options.apiKey) {
    throw new Error("API key is required");
  }

  if (!this.options.workspaceId.startsWith("T")) {
    throw new Error("Invalid workspace ID format");
  }
}
```

### 5. Resource Cleanup

Always clean up resources in deactivation:

```typescript
async postDeactivate(): Promise<void> {
  // Cancel pending tasks
  await this.cancelAllTasks();

  // Delete callbacks
  await this.deleteAllCallbacks();

  // Clear stored data
  await this.clearAll();
}
```

### 6. Avoid Instance State

Use Store instead of instance variables:

```typescript
// ❌ WRONG - Instance state doesn't persist
class MyTool extends Tool<MyTool> {
  private cache: Map<string, any> = new Map();
}

// ✅ CORRECT - Use Store
class MyTool extends Tool<MyTool> {
  async getFromCache(key: string) {
    return await this.get<any>(`cache:${key}`);
  }

  async setInCache(key: string, value: any) {
    await this.set(`cache:${key}`, value);
  }
}
```

### 7. Document Your API

Add JSDoc comments for documentation:

````typescript
/**
 * Fetches all open issues from the GitHub repository.
 *
 * @returns Promise resolving to array of GitHub issues
 * @throws Error if GitHub API is unavailable
 *
 * @example
 * ```typescript
 * const issues = await this.tools.github.getIssues();
 * ```
 */
async getIssues(): Promise<GitHubIssue[]> {
  // Implementation
}
````

---

## Next Steps

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Learn from built-in tool patterns
- **[Advanced Topics](ADVANCED.md)** - Complex tool patterns
- **API Reference** - Explore the Tool class API
