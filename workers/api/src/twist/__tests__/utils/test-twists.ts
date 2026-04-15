
/**
 * SimpleTwist - Basic twist with just lifecycle methods
 */
export class SimpleTwist {
  private twistInstanceId: string;
  private toolShed: any;
  private activateCalled = false;
  private deactivateCalled = false;

  constructor(twistInstanceId: string, toolShed: any) {
    this.twistInstanceId = twistInstanceId;
    this.toolShed = toolShed;
  }

  build(_buildFn: any) {
    return {};
  }

  async waitForReady() {
    // No tools to wait for
  }

  async activate() {
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
  private twistInstanceId: string;
  private toolShed: any;
  private tools: any = null;

  constructor(twistInstanceId: string, toolShed: any) {
    this.twistInstanceId = twistInstanceId;
    this.toolShed = toolShed;
  }

  build(_buildFn: any) {
    // Request no tools, just use built-in ones
    return {};
  }

  async waitForReady() {
    this.tools = this.toolShed.getTools();
  }

  async activate() {
    // Use store to save activation state
    await this.tools.store.set("activated", true);
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
  constructor(_twistInstanceId: string, _options: any) {
    // Built-in tools have empty constructors
  }
}

/**
 * MockRegularTool - Simulates a regular tool that requests other tools
 */
export class MockRegularTool {
  private twistInstanceId: string;
  private options: any;
  private toolShed: any;
  private tools: any = null;
  public preActivateCalled = false;
  public postActivateCalled = false;
  public preDeactivateCalled = false;
  public postDeactivateCalled = false;

  constructor(twistInstanceId: string, options: any, toolShed: any) {
    this.twistInstanceId = twistInstanceId;
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

  async preActivate() {
    this.preActivateCalled = true;
  }

  async postActivate() {
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
  private twistInstanceId: string;
  private toolShed: any;
  private tools: any = null;

  constructor(twistInstanceId: string, toolShed: any) {
    this.twistInstanceId = twistInstanceId;
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

  async activate() {
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
      constructor(twistInstanceId, toolShed) {
        this.twistInstanceId = twistInstanceId;
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
