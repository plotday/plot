import { WorkerEntrypoint } from "cloudflare:workers";

import { type Activity, type Priority } from "@plotday/sdk/plot";

import { type ToolDependencies } from ".";

const MODULE = `
import { WorkerEntrypoint } from "cloudflare:workers";

import AgentConstructor from "agent.js";

class CachedTools {
  constructor(dependencies, priorityAgentId) {
    this.dependencies = dependencies;
    this.priorityAgentId = priorityAgentId;
    this.cache = new Map();
  }

  get(ToolClass) {
    return this.getById(ToolClass.name, ToolClass);
  }

  getById(id, constructor) {
    // Check cache first
    if (this.cache.has(id)) {
      return this.cache.get(id);
    }

    // Use pre-built tool if available (for built-in tools)
    const dep = this.dependencies.find((d) => d.id === id);
    if (dep?.tool) {
      this.cache.set(id, dep.tool);
      return dep.tool;
    }

    // Otherwise construct it lazily using the constructor from the dependency
    if (!constructor) {
      throw new Error(
        \`No constructor available for tool: \${id}. Tool must be imported and used via tools.get() to be auto-discovered.\`
      );
    }
    const tools = new CachedTools(dep?.dependencies ?? [], this.priorityAgentId);
    const tool = new constructor(this.priorityAgentId, tools);
    this.cache.set(id, tool);
    return tool;
  }
}

class DependencyTracker {
  constructor() {
    this.dependencies = [];
    this.httpPermissions = [];
  }

  get(ToolClass) {
    const toolId = ToolClass.name;

    // Create nested tracker to capture this tool's dependencies
    const nestedTracker = new DependencyTracker();

    // Try to construct the tool to trigger its dependency requests
    try {
      new ToolClass(toolId, nestedTracker);
    } catch (e) {
      // Expected to fail - we're just capturing dependency requests
    }

    // Build ToolDependencies entry directly
    const dep = {
      id: toolId,
    };

    // Include dependencies if any were requested by this tool
    if (nestedTracker.dependencies.length > 0) {
      dep.dependencies = nestedTracker.dependencies;
    }

    // Include HTTP permissions if any were requested by this tool
    if (nestedTracker.httpPermissions.length > 0) {
      dep.httpPermissions = nestedTracker.httpPermissions;
    }

    // Add to dependencies array
    this.dependencies.push(dep);

    // Return mock object (construction will likely fail later, but we don't care)
    return {};
  }

  enableInternet(urls) {
    // Track HTTP permissions requested
    if (Array.isArray(urls)) {
      this.httpPermissions.push(...urls);
    }
  }

  buildDependencyTree() {
    return this.dependencies;
  }
}

function buildAgent(dependencies, priorityAgentId) {
  const tools = new CachedTools(dependencies, priorityAgentId);
  return new AgentConstructor(priorityAgentId, tools);
}

function callCallback(target, functionName, args, context) {
  const fn = target[functionName];
  if (typeof fn !== "function") {
    return Promise.reject(\`Callback function '\${functionName}' not found.\`);
  }
  return fn.call(target, args, context);
}

export default class extends WorkerEntrypoint {
  async fetch() {
    return new Response("OK");
  }

  async activate(dependencies, priority, priorityAgentId) {
    const agent = buildAgent(dependencies, priorityAgentId);
    return agent.activate(priority);
  }

  async activity(dependencies, activity, changes, priorityAgentId) {
    const agent = buildAgent(dependencies, priorityAgentId);
    return agent.activity(activity, changes);
  }

  async callCallback(dependencies, path, functionName, args, context, priorityAgentId) {
    const agent = buildAgent(dependencies, priorityAgentId);

    // If no path, call on agent directly
    if (path.length === 0) {
      return callCallback(agent, functionName, args, context);
    }

    // Navigate through the tool tree to find the target tool
    let currentTools = agent.tools;
    let targetTool = null;

    for (const pathId of path) {
      targetTool = currentTools.getById(pathId);
      if (!targetTool) {
        return Promise.reject(\`Tool path \${path.join('/')} not found\`);
      }
      // Move to the next level in the tool tree
      currentTools = targetTool.tools;
    }

    return callCallback(targetTool, functionName, args, context);
  }

  getDependencies(id) {
    const tracker = new DependencyTracker();

    try {
      // Construct agent to trigger dependency requests
      new AgentConstructor(id, tracker);
    } catch (e) {
      // Expected to fail since we're passing mock tools
      // We only care about what was requested, not actual execution
    }

    // Build and return the complete dependency tree
    return tracker.buildDependencyTree();
  }
}
`;

export abstract class AgentEntrypoint extends WorkerEntrypoint {
  static Module = MODULE;

  abstract fetch(): Promise<Response>;

  abstract activate(
    _dependencies: ToolDependencies[],
    _priority: Pick<Priority, "id">,
    _priorityAgentId: string
  ): Promise<void>;

  abstract activity(
    _dependencies: ToolDependencies[],
    _activity: Activity,
    _changes: { previous: Activity } | undefined,
    _priorityAgentId: string
  ): void;

  abstract callCallback(
    _dependencies: ToolDependencies[],
    _path: string[],
    _functionName: string,
    _args: any,
    _context: any,
    _priorityAgentId: string
  ): Promise<any>;

  abstract getDependencies(_id: string): ToolDependencies[];
}

export default AgentEntrypoint;
