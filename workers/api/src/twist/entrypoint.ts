import { WorkerEntrypoint } from "cloudflare:workers";

import { type Focus } from "@plotday/twister/plot";
import { type ITool } from "@plotday/twister/tool";

const MODULE = `
import { WorkerEntrypoint } from "cloudflare:workers";

import TwistConstructor from "twist.js";

// Intercept fetch to detect and log HTTP proxy 403 violations.
// The HttpProxy (globalOutbound) blocks requests to URLs not in the Network tool's
// allowed list and returns a 403 JSON response. Since the proxy runs as a separate
// entrypoint, its logs don't appear in twist logs. This wrapper ensures blocked
// requests produce a clear console.error visible in the twist's log stream.
const _originalFetch = globalThis.fetch;
globalThis.fetch = async function(input, init) {
  const response = await _originalFetch.call(globalThis, input, init);
  if (response.status === 403) {
    try {
      const cloned = response.clone();
      const body = await cloned.json();
      if (body?.error === "Forbidden" && body?.allowedPatterns) {
        console.error("[NETWORK VIOLATION]", body.message);
      }
    } catch {}
  }
  return response;
};

class ToolShed {
  constructor(path, twistInstanceId, builtInToolFactory, rootToolShed) {
    this.path = path || [];
    this.twistInstanceId = twistInstanceId;
    this.builtInToolFactory = builtInToolFactory;
    this.rootToolShed = rootToolShed || this;
    this.twist = null; // Set by buildTwist() on the root ToolShed only
    this.requested = new Set();
    this.built = new Map();
    this.options = new Map();
    this.children = new Map();
    this.locked = false;
    this.toolPromises = null;
    this.resolvedTools = null;
    this.initComplete = false;
    // Track every built-in tool RPC stub created under this twist build so
    // they can be released after the entrypoint method returns. Without this,
    // the Workers runtime emits "An RPC stub was not disposed properly" once
    // the GC eventually collects them. Only the root ToolShed owns the list;
    // child sheds reference the same array.
    this.disposables = rootToolShed ? rootToolShed.disposables : [];

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
    const id = ToolClass.toolId || ToolClass.name;

    // Enforce build-only usage: throw error if locked
    if (this.locked) {
      throw new Error(\`ToolShed.build() can only be called within the build method. Tool '\${id}' cannot be requested after initialization is complete.\`);
    }

    // Enforce single-use: throw error if already requested
    if (this.requested.has(id)) {
      const location = this.path.length > 0 ? \`in \${this.path.join(' > ')}\` : 'in twist build';
      throw new Error(\`Tool '\${id}' can only be requested once per build. build(\${id}) was called multiple times \${location}.\`);
    }
    this.requested.add(id);

    const toolPath = this.path.concat([id]);

    // Create nested ToolShed for this tool
    const toolShed = new ToolShed(
      toolPath,
      this.twistInstanceId,
      this.builtInToolFactory,
      this.rootToolShed
    );

    // Check if this is a built-in tool (empty object after construction)
    const testInstance = new ToolClass(this.twistInstanceId, options || {});
    const isBuiltIn = Object.keys(testInstance).length === 0;

    let tool;
    if (isBuiltIn) {
      // Built-in tool: use factory
      tool = await this.builtInToolFactory(toolPath, id, options);
      this.rootToolShed.disposables.push(tool);
    } else {
      // Regular tool: construct with id, options, and toolShed
      tool = new ToolClass(this.twistInstanceId, options, toolShed);

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
    const tool = await this.builtInToolFactory(toolPath, id, options);
    this.rootToolShed.disposables.push(tool);
    // Register so getByPath() can resolve scheduled-callback paths like ["Tasks"].
    // Don't overwrite an explicit build() registration for the same id.
    if (!this.built.has(id)) {
      this.built.set(id, tool);
      this.options.set(id, options);
    }
    return tool;
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

    // Intercept callbacks.run() for local execution optimization.
    //
    // Without this, callbacks.run() goes through the full reconstruction path:
    //   twist worker → RPC → Callbacks built-in → CallbacksState DO →
    //   2 Supabase queries → twistFactory → new worker → rebuild tool tree → execute
    //
    // With this intercept, we short-circuit to:
    //   twist worker → RPC → CallbacksState.resolve() (SQLite only) →
    //   execute directly on the already-constructed local tool tree
    //
    // The resolve() method returns just the callback metadata (path, functionName,
    // extraArgs) without executing. We then navigate the local tool tree to find
    // the target and call the function directly.
    //
    // Falls back to the original run() (full reconstruction) if:
    //   - The callback can't be resolved (not found, expired)
    //   - The target tool isn't found in the local tree
    //
    // See also:
    //   - CallbacksState.resolve() in state/callbacks.ts
    //   - Callbacks.resolve() in twist/tools/callbacks.ts
    const callbacksRpc = builtInTools.callbacks;
    const rootTools = this.rootToolShed;
    builtInTools.callbacks = new Proxy(callbacksRpc, {
      get(target, prop) {
        if (prop === 'run') {
          return async (token, ...args) => {
            const resolved = await target.resolve(token);
            if (!resolved) return target.run(token, ...args);

            // Find target in the local tool tree
            let execTarget;
            if (resolved.path.length === 0) {
              // Twist-level callback
              execTarget = rootTools.twist;
            } else {
              const { tool } = rootTools.getByPath(resolved.path);
              execTarget = tool;
            }

            if (!execTarget) return target.run(token, ...args);

            const allArgs = [...(args ?? []), ...(resolved.extraArgs ?? [])];
            const result = await callCallback(execTarget, resolved.functionName, ...allArgs);

            if (resolved.callOnce) {
              await target.delete(token);
            }

            return result;
          };
        }
        // Do NOT pass receiver - RPC stubs need their original context.
        // Passing the Proxy as receiver causes "Illegal invocation" errors.
        return Reflect.get(target, prop);
      }
    });

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

  // Release every built-in tool RPC stub captured during this build. Safe to
  // call once at the end of an entrypoint method (success or error path).
  disposeAll() {
    if (this.rootToolShed !== this) {
      return this.rootToolShed.disposeAll();
    }
    for (const stub of this.disposables) {
      try {
        if (stub && typeof stub.dispose === 'function') {
          stub.dispose();
        }
      } catch {
        // Disposing a stub that's already been disposed (or whose connection
        // dropped) shouldn't break the lifecycle method. Swallow silently.
      }
    }
    this.disposables.length = 0;
  }
}

async function buildTwist(twistInstanceId, userId, builtInToolFactory) {
  // Check if the twist is a Connector (has isConnector static property)
  const isConnector = TwistConstructor.isConnector === true;

  // Enforce bidirectional tool access:
  // - Connectors cannot use Plot (must use integrations.saveLink() instead)
  // - Twists cannot use Integrations (only Connectors can)
  const wrappedFactory = (path, id, options) => {
    if (isConnector && id === "Plot") {
      throw new Error(
        "Connectors cannot use the Plot tool directly. Use integrations.saveLink() instead."
      );
    }
    if (!isConnector && id === "Integrations") {
      throw new Error(
        "Twists cannot use the Integrations tool. Only Connectors can use integrations."
      );
    }
    if (isConnector && id === "AI") {
      throw new Error(
        "Connectors cannot use the AI tool. Only Twists can use AI capabilities."
      );
    }
    return builtInToolFactory(path, id, options);
  };

  // Create ToolShed
  const toolShed = new ToolShed([], twistInstanceId, wrappedFactory);

  // Construct twist with toolShed
  const twist = new TwistConstructor(twistInstanceId, toolShed);

  // Populate the workspace-owner user ID exposed to the twist as this.userId.
  // The SDK declares this field on Twist; the runtime injects it before any
  // lifecycle method runs.
  if (userId) {
    twist.userId = userId;
  }

  // Store twist on root ToolShed so the callbacks.run() intercept
  // can execute twist-level callbacks locally (path=[])
  toolShed.twist = twist;

  // Call twist's build method to get dependencies
  const buildResult = twist.build(toolShed.build);
  toolShed.toolPromises = buildResult;

  // Wait for twist to be ready
  await twist.waitForReady();

  toolShed.locked = true;
  return { twist, tools: toolShed };
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
    if (isBuiltIn) {
      // Built-in tools: tryCallCallback returns undefined if method doesn't exist
      const result = await tool.tryCallCallback(methodName, ...args);

      // Handle __dispatch returns from built-in tool lifecycle methods
      if (result && result.__dispatch && Array.isArray(result.__dispatch)) {
        const options = toolBuilder.options.get(toolId);
        const toolPath = toolBuilder.path.concat([toolId]);

        for (const callbackInfo of result.__dispatch) {
          // sourceMethod dispatch: call method directly on twist instance (Source pattern)
          if (callbackInfo?.sourceMethod && callbackInfo?.args) {
            const twist = toolBuilder.rootToolShed.twist;
            const method = twist[callbackInfo.sourceMethod];
            if (typeof method === 'function') {
              if (callbackInfo.forwardTo) {
                const cbResult = await method.call(twist, ...callbackInfo.args);
                await tool.callCallback(
                  callbackInfo.forwardTo.functionName,
                  ...callbackInfo.forwardTo.prependArgs,
                  cbResult
                );
              } else {
                await method.call(twist, ...callbackInfo.args);
              }
            }
          }
          // optionPath dispatch: navigate options object to find callback (legacy pattern)
          else if (callbackInfo?.optionPath && callbackInfo?.args && options) {
            let cb = options;
            for (const key of callbackInfo.optionPath) {
              cb = cb?.[key];
              if (!cb) break;
            }

            if (typeof cb === 'function') {
              // Context: parent tool or twist (root)
              let context;
              if (toolPath.length > 1) {
                const parentPath = toolPath.slice(0, -1);
                context = toolBuilder.rootToolShed.getByPath(parentPath).tool;
              } else {
                context = toolBuilder.rootToolShed.twist;
              }

              try {
                if (callbackInfo.forwardTo) {
                  const cbResult = await cb.call(context, ...callbackInfo.args);
                  await tool.callCallback(
                    callbackInfo.forwardTo.functionName,
                    ...callbackInfo.forwardTo.prependArgs,
                    cbResult
                  );
                } else {
                  await cb.call(context, ...callbackInfo.args);
                }
              } catch (error) {
                throw error;
              }
            }
          }
        }
      }
    } else if (typeof tool[methodName] === 'function') {
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
    if (isBuiltIn) {
      // Built-in tools: tryCallCallback returns undefined if method doesn't exist
      await tool.tryCallCallback(methodName, ...args);
    } else if (typeof tool[methodName] === 'function') {
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

  async init(twistInit) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      ({ tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));
    } finally {
      tools?.disposeAll();
    }
  }

  /**
   * Returns connector metadata (provider, scopes, linkTypes) from the Connector instance.
   * Called by the factory to pass connector config to the Integrations built-in tool.
   * Returns null for regular twists.
   */
  async getSourceMetadata(twistInit) {
    const isConnector = TwistConstructor.isConnector === true;
    if (!isConnector) return null;

    let tools;
    try {
      const built = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory);
      tools = built.tools;
      const twist = built.twist;
      return {
        provider: twist.provider,
        scopes: twist.scopes,
        linkTypes: twist.linkTypes || [],
        ...(TwistConstructor.handleReplies ? { handleReplies: true } : {}),
        ...(twist.singleChannel ? { singleChannel: true } : {}),
        ...(twist.channelNoun ? { channelNoun: twist.channelNoun } : {}),
        ...(twist.autoEnableNewChannelsByDefault ? { autoEnableNewChannelsByDefault: true } : {}),
        ...(twist.access ? { access: twist.access } : {}),
        ...(twist.shared ? { shared: true } : {}),
        ...(twist.keyOption ? { keyOption: twist.keyOption } : {}),
      };
    } finally {
      tools?.disposeAll();
    }
  }

  async activate(twistInit, context) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      let twist;
      ({ twist, tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preActivate', context);

      // Connector-aware activation: Connectors receive { auth, actor } instead of context
      const isConnector = TwistConstructor.isConnector === true;
      if (isConnector && context?.auth) {
        const sourceContext = {
          auth: context.auth,
          actor: context.actor ? { id: context.actor.id, type: context.actor.type } : undefined,
        };
        await twist.activate(sourceContext);
      } else {
        // Regular twist activation
        const twistContext = context ? { actor: { id: context.actor.id, type: context.actor.type } } : undefined;
        await twist.activate(twistContext);
      }

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postActivate', context);
    } catch (error) {
      // Wrap in TwistError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        twistStack: error.stack || '',
        operation: 'activate',
        originalError: error.name || 'Error',
      };
      const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
      twistError.name = 'TwistError';
      throw twistError;
    } finally {
      tools?.disposeAll();
    }
  }

  async upgrade(twistInit) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      let twist;
      ({ twist, tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preUpgrade');

      // Twist method
      await twist.upgrade();

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postUpgrade');
    } catch (error) {
      // Wrap in TwistError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        twistStack: error.stack || '',
        operation: 'upgrade',
        originalError: error.name || 'Error',
      };
      const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
      twistError.name = 'TwistError';
      throw twistError;
    } finally {
      tools?.disposeAll();
    }
  }

  async deactivate(twistInit) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      let twist;
      ({ twist, tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));

      // Pre-phase: deepest tools first
      await callPreLifecycle(tools, 'preDeactivate');

      // Twist method
      await twist.deactivate();

      // Post-phase: top-level tools first
      await callPostLifecycle(tools, 'postDeactivate');
    } catch (error) {
      // Wrap in TwistError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        twistStack: error.stack || '',
        operation: 'deactivate',
        originalError: error.name || 'Error',
      };
      const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
      twistError.name = 'TwistError';
      throw twistError;
    } finally {
      tools?.disposeAll();
    }
  }

  async callCallback(twistInit, path, functionName, ...args) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      let twist;
      ({ twist, tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));

      // If no path, call on twist directly
      if (path.length === 0) {
        return callCallback(twist, functionName, ...args);
      }

      // Navigate through the tool tree to find the target tool and its options
      const { tool, options } = tools.getByPath(path);
      if (!tool) {
        throw new Error("Tool not found at path [" + path.join(" > ") + "]. The tool may have been removed or renamed.");
      }
      const result = await callCallback(tool, functionName, ...args);

      // Handle dispatch-style returns from built-in tools.
      // Built-in tools return { __dispatch: [...] } when they need callbacks
      // invoked locally on the twist worker with proper \`this\` binding.
      // This solves the RPC stub \`this\` binding issue where callbacks like
      // onSyncEnabled/onSyncDisabled lose their context when called via RPC.
      if (result && result.__dispatch && Array.isArray(result.__dispatch)) {
        // Helper: route an error through the dispatch entry's onFailure
        // handler (if any) before rethrowing. onFailure is currently used
        // by Integrations.applyChannelEnabled to clear the channel's
        // syncing state when onChannelEnabled throws — without this the
        // UI sticks on "syncing" forever after an unhandled exception.
        const runFailureHandler = async (callbackInfo, error) => {
          const f = callbackInfo?.onFailure;
          if (!f || !f.functionName || !Array.isArray(f.args)) return;
          try {
            await tool.callCallback(f.functionName, ...f.args);
          } catch (failureError) {
            console.warn(
              "onFailure handler threw for " + f.functionName + ":",
              failureError
            );
          }
        };

        for (const callbackInfo of result.__dispatch) {
          // sourceMethod dispatch: call method directly on twist instance (Source pattern)
          if (callbackInfo?.sourceMethod && callbackInfo?.args) {
            const method = twist[callbackInfo.sourceMethod];
            if (typeof method === 'function') {
              try {
                if (callbackInfo.forwardTo) {
                  const cbResult = await method.call(twist, ...callbackInfo.args);
                  await tool.callCallback(
                    callbackInfo.forwardTo.functionName,
                    ...callbackInfo.forwardTo.prependArgs,
                    cbResult
                  );
                } else {
                  await method.call(twist, ...callbackInfo.args);
                }
              } catch (error) {
                await runFailureHandler(callbackInfo, error);
                throw error;
              }
            }
          }
          // optionPath dispatch: navigate options object to find callback (legacy pattern)
          else if (callbackInfo?.optionPath && callbackInfo?.args && options) {
            // Navigate the option path to find the callback function
            let cb = options;
            for (const key of callbackInfo.optionPath) {
              cb = cb?.[key];
              if (!cb) break;
            }

            if (typeof cb === 'function') {
              // Determine the correct this context:
              // If path has > 1 element, the parent tool owns the callback
              // If path has 1 element, the twist owns the callback
              let context;
              if (path.length > 1) {
                const parentPath = path.slice(0, -1);
                context = tools.getByPath(parentPath).tool;
              } else {
                context = twist;
              }

              try {
                if (callbackInfo.forwardTo) {
                  // forwardTo: call callback locally, then forward result to built-in tool
                  const cbResult = await cb.call(context, ...callbackInfo.args);
                  await tool.callCallback(
                    callbackInfo.forwardTo.functionName,
                    ...callbackInfo.forwardTo.prependArgs,
                    cbResult
                  );
                } else {
                  await cb.call(context, ...callbackInfo.args);
                }
              } catch (error) {
                await runFailureHandler(callbackInfo, error);
                throw error;
              }
            }
          }
        }
        return result.value;
      }

      return result;
    } catch (error) {
      // Wrap in TwistError to preserve stack across RPC boundary
      // Encode all error data in the message since custom properties don't survive RPC
      const errorData = {
        message: error.message,
        twistStack: error.stack || '',
        operation: "callCallback(" + functionName + ")",
        originalError: error.name || 'Error',
      };
      const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
      twistError.name = 'TwistError';
      throw twistError;
    } finally {
      tools?.disposeAll();
    }
  }

  // IMPORTANT: This method and callCallback both process dispatch results
  // (the { sourceMethod, forwardTo, deferredNoteKeyUpdate, ... } shapes that
  // a tool's dispatch() returns). They must stay in sync. When a built-in
  // tool (e.g. Integrations) adds a NEW dispatch field — forwardTo variants,
  // new deferred* hooks, etc. — you MUST mirror the handling into BOTH
  // functions, or callbacks routed through one path silently no-op.
  // Existing fields: sourceMethod, optionPath, args, forwardTo, onFailure,
  // deferredTagRemoval, deferredNoteKeyUpdate. Grep each to verify.
  // (No backticks in this file — it is consumed as a template literal; see
  // the escaped \` usages in console.debug below.)
  async dispatchToTool(twistInit, paths, optionPath, ...args) {
    console.debug(\`[TWIST_CONTEXT] twistInstanceId=\${twistInit.twistInstanceId}\`);
    let tools;
    try {
      let twist;
      // Build twist ONCE for all paths
      ({ twist, tools } = await buildTwist(twistInit.twistInstanceId, twistInit.userId, twistInit.builtInToolFactory));

      // Loop through all paths
      for (const path of paths) {
        // Navigate through the tool tree to find the target tool and options
        const { tool, options } = tools.getByPath(path);

        // Call dispatch on the tool if it exists
        if (tool && typeof tool.dispatch === 'function') {
          const callbacks = await tool.dispatch(optionPath, ...args);

          // Iterate over all callbacks returned by dispatch.
          // The Twisting tag is cleared fail-closed in the API queue handler
          // (workers/api/src/queue/updates.ts), not here — each callback just
          // runs its body and surfaces any errors.
          // Helper: route an error through the dispatch entry's onFailure
          // handler (if any) before rethrowing. Mirrors the runFailureHandler
          // in callCallback above. Used by Integrations.applyChannelEnabled
          // to clear "syncing" state when onChannelEnabled throws.
          const runFailureHandler = async (callbackInfo, error) => {
            const f = callbackInfo?.onFailure;
            if (!f || !f.functionName || !Array.isArray(f.args)) return;
            if (typeof tool.callCallback !== 'function') return;
            try {
              await tool.callCallback(f.functionName, ...f.args);
            } catch (failureError) {
              console.warn(
                "onFailure handler threw for " + f.functionName + ":",
                failureError
              );
            }
          };

          for (const callbackInfo of callbacks) {
            // sourceMethod dispatch: call method directly on twist instance (Source pattern)
            if (callbackInfo?.sourceMethod && callbackInfo?.args) {
              const method = twist[callbackInfo.sourceMethod];
              if (typeof method === 'function') {
                try {
                  const cbResult = await method.call(twist, ...callbackInfo.args);

                  // forwardTo: pass the twist method's result into a built-in tool
                  // callback (e.g. onCreateLink → saveCreatedLink). Mirrors the
                  // forwardTo handling in callCallback above.
                  if (callbackInfo.forwardTo && typeof tool.callCallback === 'function') {
                    await tool.callCallback(
                      callbackInfo.forwardTo.functionName,
                      ...callbackInfo.forwardTo.prependArgs,
                      cbResult
                    );
                  }

                  // Dispatch origin: onNoteCreated / onNoteUpdated.
                  //   - Plain string return  -> set note.key only (legacy).
                  //   - NoteWriteBackResult  -> set key + refresh sync baseline
                  //     (external_content_hash) from externalContent. Lets the
                  //     next sync-in recognize the round-tripped external state
                  //     and preserve Plot's (possibly richer) content.
                  if (callbackInfo.deferredNoteKeyUpdate) {
                    const noteId = callbackInfo.deferredNoteKeyUpdate.noteId;
                    try {
                      if (typeof cbResult === 'string') {
                        if (typeof tool.updateNoteKey === 'function') {
                          await tool.updateNoteKey(noteId, cbResult);
                        }
                      } else if (cbResult && typeof cbResult === 'object') {
                        if (typeof tool.updateNoteBaseline === 'function') {
                          await tool.updateNoteBaseline(noteId, cbResult);
                        }
                      }
                    } catch (keyError) {
                      console.warn('Failed to update note baseline:', keyError);
                    }
                  }
                } catch (error) {
                  await runFailureHandler(callbackInfo, error);
                  // Tier-B "Failed to send" fallback: a note write-back
                  // (onNoteCreated / onNoteUpdated, identified by
                  // deferredNoteKeyUpdate) that THROWS means the send did not
                  // happen. Mark the originating note so the user sees a
                  // generic "Failed to send" affordance even when the connector
                  // didn't return a structured deliveryError. Best-effort: a
                  // failure here must not mask the original error.
                  if (
                    callbackInfo.deferredNoteKeyUpdate?.noteId &&
                    typeof tool.markSendFailed === 'function'
                  ) {
                    try {
                      await tool.markSendFailed(
                        callbackInfo.deferredNoteKeyUpdate.noteId,
                        { code: 'send_failed', message: null }
                      );
                    } catch (markError) {
                      console.warn('Failed to mark note send-failed:', markError);
                    }
                  }
                  const errorData = {
                    message: error instanceof Error ? error.message : String(error),
                    twistStack: error instanceof Error ? error.stack || '' : '',
                    operation: \`dispatch sourceMethod: \${callbackInfo.sourceMethod}\`,
                    originalError: error instanceof Error ? error.name : 'Error',
                  };
                  const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
                  twistError.name = 'TwistError';
                  throw twistError;
                }
              }
            }
            // optionPath dispatch: navigate options object to find callback (legacy pattern)
            else if (callbackInfo && callbackInfo.optionPath && callbackInfo.args && options) {
              // Navigate the option path to find the callback
              let callback = options;
              for (const key of callbackInfo.optionPath) {
                callback = callback?.[key];
                if (!callback) break;
              }

              // Call the callback if it's a function, binding to the correct context
              if (typeof callback === 'function') {
                try {
                  // Determine the correct context for the callback
                  // If path has > 1 element, the parent tool owns the callback
                  // If path has 1 element, the twist owns the callback
                  let callbackContext;
                  if (path.length > 1) {
                    // Get parent tool (e.g., "GoogleCalendar" from ["GoogleCalendar", "Plot"])
                    const parentPath = path.slice(0, -1);
                    const { tool: parentTool } = tools.getByPath(parentPath);
                    callbackContext = parentTool;
                  } else {
                    // Direct twist callback (path like ["Plot"])
                    callbackContext = twist;
                  }

                  await callback.call(callbackContext, ...callbackInfo.args);
                } catch (error) {
                  await runFailureHandler(callbackInfo, error);
                  // Wrap in TwistError to preserve stack across RPC boundary
                  const errorData = {
                    message: error instanceof Error ? error.message : String(error),
                    twistStack: error instanceof Error ? error.stack || '' : '',
                    operation: \`dispatch callback: \${callbackInfo.optionPath.join('.')}\`,
                    originalError: error instanceof Error ? error.name : 'Error',
                  };
                  const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
                  twistError.name = 'TwistError';
                  throw twistError;
                }
              }
            }
          }
        }
      }
    } catch (error) {
      // Wrap errors (from twist build OR callback execution)
      const errorData = {
        message: error instanceof Error ? error.message : String(error),
        twistStack: error instanceof Error ? error.stack || '' : '',
        operation: \`dispatchToTool(\${paths.length} path\${paths.length > 1 ? 's' : ''})\`,
        originalError: error instanceof Error ? error.name : 'Error',
      };
      const twistError = new Error("__TWIST_ERROR__" + JSON.stringify(errorData));
      twistError.name = 'TwistError';
      throw twistError;
    } finally {
      tools?.disposeAll();
    }
  }
}
`;

type BuiltInToolFactory = (
  path: string[],
  toolId: string,
  options?: any
) => ITool;

export interface TwistInit {
  twistInstanceId: string;
  /** The user ID (`twist_instance.owner_id`) that installed this twist. */
  userId: string;
  builtInToolFactory: BuiltInToolFactory;
}

export abstract class TwistEntrypoint extends WorkerEntrypoint {
  static Module = MODULE;

  abstract fetch(): Promise<Response>;

  abstract init(_twistInit: TwistInit): Promise<void>;

  abstract getSourceMetadata(
    _twistInit: TwistInit
  ): Promise<{ provider?: string; scopes?: string[]; access?: string[]; linkTypes: any[]; shared?: boolean; keyOption?: string } | null>;

  abstract activate(
    _twistInit: TwistInit,
    _priority: Pick<Focus, "id">,
    _context?: { actor: { id: string; type: number } }
  ): Promise<void>;

  abstract upgrade(_twistInit: TwistInit): Promise<void>;

  abstract deactivate(_twistInit: TwistInit): Promise<void>;

  abstract callCallback(
    _twistInit: TwistInit,
    _path: string[],
    _functionName: string,
    ..._args: any[]
  ): Promise<any>;

  abstract dispatchToTool(
    _twistInit: TwistInit,
    _paths: string[][],
    _optionPath: string[],
    ..._args: any[]
  ): Promise<void>;
}

export default TwistEntrypoint;
