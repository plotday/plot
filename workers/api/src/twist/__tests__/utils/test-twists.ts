import type { Priority } from "@plotday/twister/plot";

/**
 * SimpleTwist - Basic twist with just lifecycle methods
 */
export class SimpleTwist {
  private priorityTwistId: string;
  private toolShed: any;
  private activateCalled = false;
  private deactivateCalled = false;

  constructor(priorityTwistId: string, toolShed: any) {
    this.priorityTwistId = priorityTwistId;
    this.toolShed = toolShed;
  }

  build(_buildFn: any) {
    return {};
  }

  async waitForReady() {
    // No tools to wait for
  }

  async activate(_priority: Pick<Priority, "id">) {
    this.activateCalled = true;
  }

  async deactivate() {
    this.deactivateCalled = true;
  }

  async upgrade() {
    // No-op for simple twist
  }

  getState() {
    return {
      activateCalled: this.activateCalled,
      deactivateCalled: this.deactivateCalled,
    };
  }
}

/**
 * ToolUsingTwist - Twist that uses Plot, Store, and Callbacks tools
 */
export class ToolUsingTwist {
  private priorityTwistId: string;
  private toolShed: any;
  private tools: any = null;

  constructor(priorityTwistId: string, toolShed: any) {
    this.priorityTwistId = priorityTwistId;
    this.toolShed = toolShed;
  }

  build(_buildFn: any) {
    // Request no tools, just use built-in ones
    return {};
  }

  async waitForReady() {
    this.tools = this.toolShed.getTools();
  }

  async activate(priority: Pick<Priority, "id">) {
    // Use store to save activation state
    await this.tools.store.set("activated", true);
    await this.tools.store.set("priority_id", priority.id);
  }

  async deactivate() {
    await this.tools.store.set("activated", false);
  }

  async upgrade() {
    // No-op
  }

  async onWebhookReceived(data: any) {
    // Example callback function
    await this.tools.store.set("webhook_data", data);
    return { received: true };
  }
}

/**
 * MockBuiltInTool - Simulates a built-in tool for testing
 */
class _MockBuiltInTool {
  constructor(_priorityTwistId: string, _options: any) {
    // Built-in tools have empty constructors
  }
}

/**
 * MockRegularTool - Simulates a regular tool that requests other tools
 */
export class MockRegularTool {
  private priorityTwistId: string;
  private options: any;
  private toolShed: any;
  private tools: any = null;
  public preActivateCalled = false;
  public postActivateCalled = false;
  public preDeactivateCalled = false;
  public postDeactivateCalled = false;

  constructor(priorityTwistId: string, options: any, toolShed: any) {
    this.priorityTwistId = priorityTwistId;
    this.options = options;
    this.toolShed = toolShed;
  }

  build(_buildFn: any) {
    // Don't request any tools
    return {};
  }

  async waitForReady() {
    this.tools = this.toolShed.getTools();
  }

  async preActivate(_priority: Pick<Priority, "id">) {
    this.preActivateCalled = true;
  }

  async postActivate(_priority: Pick<Priority, "id">) {
    this.postActivateCalled = true;
  }

  async preDeactivate() {
    this.preDeactivateCalled = true;
  }

  async postDeactivate() {
    this.postDeactivateCalled = true;
  }

  async dispatch(_optionPath: string[], ..._args: any[]) {
    // Example dispatch handler
  }

  async onCallback(data: any) {
    return { callbackReceived: data };
  }
}

/**
 * NestedToolTwist - Twist that builds a nested tool tree
 */
export class NestedToolTwist {
  private priorityTwistId: string;
  private toolShed: any;
  private tools: any = null;

  constructor(priorityTwistId: string, toolShed: any) {
    this.priorityTwistId = priorityTwistId;
    this.toolShed = toolShed;
  }

  build(buildFn: any) {
    return {
      customTool: buildFn(MockRegularTool, { setting: "value" }),
    };
  }

  async waitForReady() {
    this.tools = this.toolShed.getTools();
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Use the nested tool
  }

  async deactivate() {
    // Cleanup
  }

  async upgrade() {
    // No-op
  }
}

/**
 * Generate twist module code for testing
 */
export function generateTestTwistModule(twistClass: string): string {
  return `
    class ${twistClass} {
      constructor(priorityTwistId, toolShed) {
        this.priorityTwistId = priorityTwistId;
        this.toolShed = toolShed;
      }

      build(buildFn) {
        return {};
      }

      async waitForReady() {
        this.tools = this.toolShed.getTools();
      }

      async activate(priority) {
        await this.tools.store.set("activated", true);
      }

      async deactivate() {
        await this.tools.store.set("activated", false);
      }

      async upgrade() {}
    }

    export default ${twistClass};
  `;
}
