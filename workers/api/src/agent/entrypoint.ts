import { WorkerEntrypoint } from "cloudflare:workers";

import { type ToolDependencies } from ".";
import { type Activity, type Priority } from "@plotday/sdk/plot";

const MODULE = `
import { WorkerEntrypoint } from "cloudflare:workers";

import AgentConstructor from "agent.js";

class CachedTools {
  constructor(dependencies) {
    this.dependencies = dependencies;
    this.cache = new Map();
  }

  get(ToolClass) {
    return this.getById(ToolClass.name);
  }

  getById(id) {
    // Check cache first
    if (this.cache.has(id)) {
      return this.cache.get(id);
    }

    // Find the dependency
    const dep = this.dependencies.find((d) => d.id === id);
    if (!dep) {
      throw new Error(\`Tool not found: \${id}\`);
    }

    // Use pre-built tool if available (for built-in tools)
    if (dep.tool) {
      this.cache.set(id, dep.tool);
      return dep.tool;
    }

    // Otherwise construct it lazily using the constructor from the dependency
    const tool = this.constructTool(
      id,
      dep.dependencies ?? [],
      dep.constructor
    );
    this.cache.set(id, tool);
    return tool;
  }

  constructTool(id, dependencies, constructor) {
    if (!constructor) {
      throw new Error(
        \`No constructor available for tool: \${id}. Tool must be imported and used via tools.get() to be auto-discovered.\`
      );
    }

    const tools = new CachedTools(dependencies);
    return new constructor(tools);
  }
}

class DependencyTracker {
  constructor() {
    this.toolRequests = new Map();
  }

  get(ToolClass) {
    const toolId = ToolClass.name;

    // Create nested tracker to capture this tool's dependencies
    const nestedTracker = new DependencyTracker();

    // Try to construct the tool to trigger its dependency requests
    try {
      new ToolClass(nestedTracker);
    } catch (e) {
      // Expected to fail - we're just capturing dependency requests
    }

    // Record this tool request and its nested dependencies
    this.toolRequests.set(toolId, {
      constructor: ToolClass,
      nestedTracker,
    });

    // Return mock object (construction will likely fail later, but we don't care)
    return {};
  }

  buildDependencyTree() {
    const result = [];

    for (const [id, { constructor, nestedTracker }] of this.toolRequests) {
      result.push({
        id,
        constructor,
        // Recursively build dependencies for this tool
        dependencies: nestedTracker.buildDependencyTree(),
      });
    }

    return result;
  }
}

function buildAgent(dependencies) {
  const tools = new CachedTools(dependencies);
  return new AgentConstructor(tools);
}

function buildTool(tool) {
  // Use pre-built tool if available, otherwise construct lazily
  if (tool.tool) {
    return tool.tool;
  } else {
    const tools = new CachedTools(tool.dependencies ?? []);
    return tools.getById(tool.id);
  }
}

function callAgent(agent, functionName, args, context) {
  const fn = agent[functionName];
  if (typeof fn !== "function") {
    return Promise.reject(\`Callback function '\${functionName}' not found on agent.\`);
  }
  return fn.call(agent, args, context);
}

function callTool(tool, functionName, args, context) {
  const fn = tool[functionName];
  if (typeof fn !== "function") {
    return Promise.reject(\`Callback function '\${functionName}' not found on tool.\`);
  }
  return fn.call(tool, args, context);
}

export default class extends WorkerEntrypoint {
  async fetch() {
    return new Response("OK");
  }

  async activate(dependencies, priority) {
    const agent = buildAgent(dependencies);
    return agent.activate(priority);
  }

  async activity(dependencies, activity, changes) {
    const agent = buildAgent(dependencies);
    return agent.activity(activity, changes);
  }

  async call(dependencies, functionName, args, context) {
    const agent = buildAgent(dependencies);
    return callAgent(agent, functionName, args, context);
  }

  async callTool(tool, functionName, args, context) {
    const target = buildTool(tool);
    return callTool(target, functionName, args, context);
  }

  getDependencies() {
    const tracker = new DependencyTracker();

    try {
      // Construct agent to trigger dependency requests
      new AgentConstructor(tracker);
    } catch (e) {
      // Expected to fail since we're passing mock tools
      // We only care about what was requested, not actual execution
    }

    // Build and return the complete dependency tree
    return tracker.buildDependencyTree();
  }
}
`;

export class AgentEntrypoint extends WorkerEntrypoint {
  static Module = MODULE;

  async fetch() {
    return new Response("OK");
  }

  async activate(
    _dependencies: ToolDependencies[],
    _priority: Pick<Priority, "id">
  ) {}

  async activity(_dependencies: ToolDependencies[], _activity: Activity, _changes?: { previous: Activity }) {}

  async call(
    _dependencies: ToolDependencies[],
    _functionName: string,
    _args: any,
    _context: any
  ): Promise<any> {}

  async callTool(
    _tool: ToolDependencies,
    _functionName: string,
    _args: any,
    _context: any
  ): Promise<any> {
    return null;
  }

  getDependencies(): ToolDependencies[] {
    return [];
  }
}

export default AgentEntrypoint;
