import { WorkerEntrypoint } from "cloudflare:workers";

import { type Priority } from "@plotday/agent/plot";
import { type ITool } from "@plotday/agent/tool";

const MODULE = `
import { WorkerEntrypoint } from "cloudflare:workers";

import AgentConstructor from "agent.js";

class ToolShed {
  constructor(path, priorityAgentId, builtInToolFactory) {
    this.path = path || [];
    this.priorityAgentId = priorityAgentId;
    this.builtInToolFactory = builtInToolFactory;
    this.requested = new Set();
    this.built = new Map();
    this.options = new Map();
    this.children = new Map();
    this.locked = false;
    this.toolPromises = null;
    this.resolvedTools = null;
    this.initComplete = false;

    // Bind build method so it can be passed around
    this.build = this._buildTool.bind(this);
  }

  get ready() {
    return this.initComplete;
  }

  getById(id) {
    return {
      tool: this.built.get(id),
      options: this.options.get(id),
      tools: this.children.get(id)
    };
  }

  getByPath(path) {
    let toolShed = this;
    let targetTool = null;
    let toolOptions = null;

    for (const pathId of path) {
      const toolInfo = toolShed.getById(pathId);
      targetTool = toolInfo.tool;
      toolOptions = toolInfo.options;
      toolShed = toolInfo.tools;
      if (!toolShed) break;
    }

    return {
      tool: targetTool,
      options: toolOptions,
    };
  }

  async _buildTool(ToolClass, options) {
    const id = ToolClass.name;

    // Enforce build-only usage: throw error if locked
    if (this.locked) {
      throw new Error(\`ToolShed.build() can only be called within the build method. Tool '\${id}' cannot be requested after initialization is complete.\`);
    }

    // Enforce single-use: throw error if already requested
    if (this.requested.has(id)) {
      const location = this.path.length > 0 ? \`in \${this.path.join(' > ')}\` : 'in agent build';
      throw new Error(\`Tool '\${id}' can only be requested once per build. build(\${id}) was called multiple times \${location}.\`);
    }
    this.requested.add(id);

    const toolPath = this.path.concat([id]);

    // Create nested ToolShed for this tool
    const toolShed = new ToolShed(
      toolPath,
      this.priorityAgentId,
      this.builtInToolFactory
    );

    // Check if this is a built-in tool (empty object after construction)
    const testInstance = new ToolClass(this.priorityAgentId, options || {});
    const isBuiltIn = Object.keys(testInstance).length === 0;

    let tool;
    if (isBuiltIn) {
      // Built-in tool: use factory
      tool = await this.builtInToolFactory(toolPath, id, options);
    } else {
      // Regular tool: construct with id, options, and toolShed
      tool = new ToolClass(this.priorityAgentId, options, toolShed);

      // Call the tool's build method to get its dependencies
      const buildResult = tool.build(toolShed.build);
      toolShed.toolPromises = buildResult;

      // Wait for tool to be ready
      await toolShed.waitForReady();
    }

    this.built.set(id, tool);
    this.options.set(id, options);
    this.children.set(id, toolShed);

    toolShed.locked = true;
    return tool;
  }

  async _buildBuiltIn(id, options) {
    const toolPath = this.path.concat([id]);
    return await this.builtInToolFactory(toolPath, id, options);
  }

  async waitForReady() {
    if (this.initComplete) return;

    if (!this.toolPromises) {
      throw new Error("ToolShed not initialized with build method");
    }

    const entries = Object.entries(this.toolPromises);
    const resolved = await Promise.all(
      entries.map(([key, promise]) => promise.then(tool => [key, tool]))
    );

    const builtInTools = {
      callbacks: await this._buildBuiltIn("Callbacks", {}),
      store: await this._buildBuiltIn("Store", {}),
      tasks: await this._buildBuiltIn("Tasks", {}),
    };

    this.resolvedTools = {
      ...Object.fromEntries(resolved),
      ...builtInTools,
    };

    this.initComplete = true;
  }

  getTools() {
    if (!this.initComplete) {
      throw new Error("Tools not ready. Call waitForReady() first.");
    }
    return this.resolvedTools;
  }
}

async function buildAgent(priorityAgentId, builtInToolFactory) {
  // Create ToolShed
  const toolShed = new ToolShed([], priorityAgentId, builtInToolFactory);

  // Construct agent with toolShed
  const agent = new AgentConstructor(priorityAgentId, toolShed);

  // Call agent's build method to get dependencies
  const buildResult = agent.build(toolShed.build);
  toolShed.toolPromises = buildResult;

  // Wait for agent to be ready
  await agent.waitForReady();

  toolShed.locked = true;
  return { agent, tools: toolShed };
}

function callCallback(target, functionName, ...args) {
  // RpcStubs are functions rather than objects
  const isBuiltIn = typeof target === 'function';
  if (isBuiltIn) {
    return target.callCallback(functionName, ...args);
  } else {
    const fn = target[functionName];
    if (typeof fn !== "function") {
      return Promise.reject(\`Callback function '\${functionName}' not found.\`);
    }
    return fn.call(target, ...args);
  }
}

async function callPreLifecycle(toolBuilder, methodName, ...args) {
  // Depth-first traversal: call on children first (deepest dependencies first)
  for (const [toolId, tool] of toolBuilder.built.entries()) {
    const childTools = toolBuilder.children.get(toolId);
    if (childTools) {
      await callPreLifecycle(childTools, methodName, ...args);
    }

    // Then call on the current tool
    // RpcStubs are functions, regular tools are objects
    const isBuiltIn = typeof tool === 'function';
    if (!isBuiltIn && typeof tool[methodName] === 'function') {
      await tool[methodName](...args);
    }
  }
}

async function callPostLifecycle(toolBuilder, methodName, ...args) {
  // Reverse order: call on current tool first, then descend to children
  for (const [toolId, tool] of toolBuilder.built.entries()) {
    // Call on the current tool first
    // RpcStubs are functions, regular tools are objects
    const isBuiltIn = typeof tool === 'function';
    if (!isBuiltIn && typeof tool[methodName] === 'function') {
      await tool[methodName](...args);
    }

    // Then call on children
    const childTools = toolBuilder.children.get(toolId);
    if (childTools) {
      await callPostLifecycle(childTools, methodName, ...args);
    }
  }
}

export default class extends WorkerEntrypoint {
  constructor(ctx, env) {
    super(ctx, env);
  }

  async fetch() {
    return new Response("OK");
  }

  async init(agentInit) {
    const { agent } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);
  }

  async activate(agentInit, priority) {
    try {
      const { agent, tools } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preActivate', priority);

      // Agent method
      await agent.activate(priority);

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postActivate', priority);
    } catch (error) {
      // Wrap in AgentError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        agentStack: error.stack || '',
        operation: 'activate',
        originalError: error.name || 'Error',
      };
      const agentError = new Error("__AGENT_ERROR__" + JSON.stringify(errorData));
      agentError.name = 'AgentError';
      throw agentError;
    }
  }

  async upgrade(agentInit) {
    try {
      const { agent, tools } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preUpgrade');

      // Agent method
      await agent.upgrade();

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postUpgrade');
    } catch (error) {
      // Wrap in AgentError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        agentStack: error.stack || '',
        operation: 'upgrade',
        originalError: error.name || 'Error',
      };
      const agentError = new Error("__AGENT_ERROR__" + JSON.stringify(errorData));
      agentError.name = 'AgentError';
      throw agentError;
    }
  }

  async deactivate(agentInit) {
    try {
      const { agent, tools } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preDeactivate');

      // Agent method
      await agent.deactivate();

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postDeactivate');
    } catch (error) {
      // Wrap in AgentError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        agentStack: error.stack || '',
        operation: 'deactivate',
        originalError: error.name || 'Error',
      };
      const agentError = new Error("__AGENT_ERROR__" + JSON.stringify(errorData));
      agentError.name = 'AgentError';
      throw agentError;
    }
  }

  async callCallback(agentInit, path, functionName, ...args) {
    try {
      const { agent, tools } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);

      // If no path, call on agent directly
      if (path.length === 0) {
        return callCallback(agent, functionName, ...args);
      }

      // Navigate through the tool tree to find the target tool
      const { tool } = tools.getByPath(path);

      return callCallback(tool, functionName, ...args);
    } catch (error) {
      // Wrap in AgentError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        agentStack: error.stack || '',
        operation: "callCallback(" + functionName + ")",
        originalError: error.name || 'Error',
      };
      const agentError = new Error("__AGENT_ERROR__" + JSON.stringify(errorData));
      agentError.name = 'AgentError';
      throw agentError;
    }
  }

  async dispatchToTool(agentInit, paths, optionPath, ...args) {
    try {
      // Build agent ONCE for all paths
      const { agent, tools } = await buildAgent(agentInit.priorityAgentId, agentInit.builtInToolFactory);

      // Loop through all paths
      for (const path of paths) {
        try {
          // Navigate through the tool tree to find the target tool and options
          const { tool, options } = tools.getByPath(path);

          // Call dispatch on the tool if it exists
          if (tool && typeof tool.dispatch === 'function') {
            const callbacks = await tool.dispatch(optionPath, ...args);

            // Iterate over all callbacks returned by dispatch
            for (const callbackInfo of callbacks) {
              // Invoke the callback locally in agent worker
              if (callbackInfo && callbackInfo.optionPath && callbackInfo.args && options) {
                // Navigate the option path to find the callback
                let callback = options;
                for (const key of callbackInfo.optionPath) {
                  callback = callback?.[key];
                  if (!callback) break;
                }

                // Call the callback if it's a function, binding agent as 'this'
                if (typeof callback === 'function') {
                  await callback.call(agent, ...callbackInfo.args);
                }
              }
            }
          }
        } catch (error) {
          // Log individual path errors but continue with other paths
          console.warn(
            \`Failed to dispatch to tool \${path[path.length-1]}:\`,
            error instanceof Error ? error.message : error
          );
        }
      }
    } catch (error) {
      // Only wrap and throw errors that occur during agent build
      const errorData = {
        message: error.message,
        agentStack: error.stack || '',
        operation: 'dispatchToTool(multiple paths)',
        originalError: error.name || 'Error',
      };
      const agentError = new Error("__AGENT_ERROR__" + JSON.stringify(errorData));
      agentError.name = 'AgentError';
      throw agentError;
    }
  }
}
`;

type BuiltInToolFactory = (
  path: string[],
  toolId: string,
  options?: any
) => ITool;

export interface AgentInit {
  priorityAgentId: string;
  builtInToolFactory: BuiltInToolFactory;
}

export abstract class AgentEntrypoint extends WorkerEntrypoint {
  static Module = MODULE;

  abstract fetch(): Promise<Response>;

  abstract init(_agentInit: AgentInit): Promise<void>;

  abstract activate(
    _agentInit: AgentInit,
    _priority: Pick<Priority, "id">
  ): Promise<void>;

  abstract upgrade(_agentInit: AgentInit): Promise<void>;

  abstract deactivate(_agentInit: AgentInit): Promise<void>;

  abstract callCallback(
    _agentInit: AgentInit,
    _path: string[],
    _functionName: string,
    ..._args: any[]
  ): Promise<any>;

  abstract dispatchToTool(
    _agentInit: AgentInit,
    _paths: string[][],
    _optionPath: string[],
    ..._args: any[]
  ): Promise<void>;
}

export default AgentEntrypoint;
