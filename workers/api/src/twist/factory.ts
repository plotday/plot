import type { Kysely } from "kysely";

import { type Priority } from "@plotday/twister/plot";

import type { DB } from "../db-types";
import { type Bindings, type TwistEnvironment } from "../env";
import { createLogger } from "@plotday/worker-util";
import { handleTwistOperation } from "./error-handling";
import { getTwist } from "./loader";
import {
  type MergedPermissions,
  type ToolPermission,
  comparePermissions,
  mergeToolPermissions,
} from "./permissions";
import {
  type ProviderDeclaration,
  collectToolPermissions,
  collectToolProviders,
  createTool,
  mergeProviderDeclarations,
} from "./tools/factory";
import { type Tool } from "./tools/tool";

export function twistFactory({
  env,
  ctx,
  db,
  checkPermissions,
  module,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  checkPermissions?: boolean;
  module?: string;
}) {
  if (!ctx.exports) {
    throw new Error("ExecutionContext exports missing");
  }
  checkPermissions ??= true;
  return async ({
    id: providedId,
    environment: providedEnvironment,
    version,
    priorityId,
    priorityTwistId,
  }: {
    id?: string;
    environment?: TwistEnvironment;
    version?: string;
    priorityId: string;
    priorityTwistId: string;
  }) => {
    const twistData = await getTwist({
      env,
      ctx,
      db,
      id: providedId,
      environment: providedEnvironment,
      version,
      priorityId,
      priorityTwistId,
      storage: env.STORAGE,
      callbacks: env.CALLBACKS,
      logSubscriptions: env.LOG_SUBSCRIPTIONS,
      module,
    });
    const twist = twistData.twist;
    const id = twistData.id!;
    const environment = twistData.environment!;
    version = twistData.version!;

    // Track tool instances for permission collection
    const toolInstances: Array<{ path: string[]; id: string; options: any }> =
      [];
    let storedPermissions: MergedPermissions | undefined;
    let storedToolPermissions: Record<string, ToolPermission[]> | undefined;

    // Track options schema captured during deployment introspection
    let optionsSchema: Record<string, unknown> | undefined;

    // Load priority_twist config for Options resolution at runtime
    let priorityTwistConfig: Record<string, unknown> | undefined;

    if (checkPermissions) {
      const config = await env.TWIST_CONFIG.get(`${id}:${version}`);
      if (!config) {
        throw new Error(`Twist configuration not found: ${id}:${version}`);
      }
      ({
        permissions: storedPermissions,
        toolPermissions: storedToolPermissions,
      } = JSON.parse(config));

      // Load user config from priority_twist for Options resolution
      if (priorityTwistId && priorityTwistId !== "__deployment__") {
        const pt = await db
          .selectFrom("priority_twist")
          .select("config")
          .where("id", "=", priorityTwistId)
          .executeTakeFirst();
        if (pt?.config) {
          priorityTwistConfig =
            typeof pt.config === "string"
              ? JSON.parse(pt.config)
              : (pt.config as Record<string, unknown>);
        }
      }
    }

    // Create factory function for constructing built-in tools at runtime
    const builtInToolFactory = (
      path: string[],
      toolId: string,
      options?: any
    ): Tool => {
      // Options tool: capture schema at deploy, resolve values at runtime
      if (toolId === "Options") {
        if (!checkPermissions) {
          // DEPLOYMENT: capture the schema for storage
          optionsSchema = options;
        }
        // Both deploy and runtime: return resolved options object
        toolInstances.push({ path, id: toolId, options });
        return createTool(path, toolId, options, {
          twistId: id,
          environment,
          db,
          priorityId,
          priorityTwistId,
          env,
          ctx,
          config: priorityTwistConfig,
        });
      }

      // SPECIAL CASE: ContactAccess.Write inheritance at runtime
      // Apply the same inheritance logic as during deployment: if ANY tool in the
      // dependency tree has ContactAccess.Write (checked via stored permissions),
      // automatically grant it to this Plot instance. This ensures Plot's internal
      // addContacts() calls (from processNewActor) will succeed.
      if (toolId === "Plot" && checkPermissions && storedToolPermissions) {
        const hasContactWrite = Object.values(storedToolPermissions).some(
          (perms) =>
            perms.some(
              (p) =>
                p.domain === "plot" &&
                p.entity === "contact" &&
                p.flags.includes("write")
            )
        );

        if (hasContactWrite) {
          const currentAccess = (options as any)?.contact?.access;
          const ContactAccessWrite = 1; // ContactAccess.Write enum value

          if (
            currentAccess === undefined ||
            currentAccess < ContactAccessWrite
          ) {
            options = {
              ...options,
              contact: {
                ...(options as any)?.contact,
                access: ContactAccessWrite,
              },
            };
          }
        }
      }

      // Validate permissions before creating tool
      const pathString = path.join(":");
      if (checkPermissions && storedToolPermissions) {
        const expected = collectToolPermissions(toolId, options);
        const stored = storedToolPermissions[pathString];

        if (!stored) {
          throw new Error(`No stored permissions for tool path: ${pathString}`);
        }

        if (!comparePermissions(expected, stored)) {
          throw new Error(
            `Permission mismatch for ${pathString}. ` +
              `Expected: ${JSON.stringify(expected)}, ` +
              `Stored: ${JSON.stringify(stored)}`
          );
        }
      }

      const tool = createTool(path, toolId, options, {
        twistId: id,
        environment,
        db,
        priorityId,
        priorityTwistId,
        env,
        ctx,
      });

      // Track tool for permission collection
      toolInstances.push({ path, id: toolId, options });

      return tool;
    };

    // Create twistInit object to pass to each twist method
    const twistInit = {
      priorityTwistId,
      builtInToolFactory,
    };

    // Initialize twist and collect/validate permissions and providers
    let permissions: MergedPermissions = {};
    let toolPermissionsMap: Record<string, ToolPermission[]> = {};
    let providers: ProviderDeclaration[] = [];
    let integrationsMap: Record<string, string> = {};

    if (!checkPermissions) {
      // DEPLOYMENT: Initialize twist to build tools and collect permissions
      await twist.init(twistInit);

      // Collect and merge permissions from all tools
      const allPermissions: ToolPermission[] = [];
      for (const { id: toolId, options } of toolInstances) {
        const perms = collectToolPermissions(toolId, options);
        allPermissions.push(...perms);
      }

      // SPECIAL CASE: ContactAccess.Write inheritance
      // When a child tool (e.g., GoogleCalendar) has ContactAccess.Write and creates
      // activities/notes with NewContact objects, the Plot tool's internal logic
      // (processNewActor) calls addContacts() to create those contacts. This means
      // parent twists/tools also need ContactAccess.Write permission, even if they
      // don't directly call addContacts().
      // Solution: If ANY tool in the dependency tree has ContactAccess.Write,
      // automatically grant it to ALL Plot tool instances.
      const hasContactWrite = allPermissions.some(
        (p) =>
          p.domain === "plot" &&
          p.entity === "contact" &&
          p.flags.includes("write")
      );

      if (hasContactWrite) {
        // Update all Plot tool instances to have ContactAccess.Write
        for (const instance of toolInstances) {
          if (instance.id === "Plot") {
            // Check if this Plot instance already has ContactAccess.Write
            const currentAccess = (instance.options as any)?.contact?.access;
            const ContactAccessWrite = 1; // ContactAccess.Write enum value

            if (
              currentAccess === undefined ||
              currentAccess < ContactAccessWrite
            ) {
              // Update options to include ContactAccess.Write
              instance.options = {
                ...instance.options,
                contact: {
                  ...(instance.options as any)?.contact,
                  access: ContactAccessWrite,
                },
              };

              // Re-collect permissions for this updated Plot instance
              const updatedPerms = collectToolPermissions(
                instance.id,
                instance.options
              );
              allPermissions.push(...updatedPerms);
            }
          }
        }
      }

      permissions = mergeToolPermissions(allPermissions);

      // Build per-path toolPermissions map for storage
      // Maps tool paths (e.g., "Plot", "Plot:Activity") to their ToolPermission arrays
      for (const { path, id: toolId, options } of toolInstances) {
        const pathString = path.join(":");
        toolPermissionsMap[pathString] = collectToolPermissions(
          toolId,
          options
        );
      }

      // Collect and merge provider declarations from all Integrations instances
      const allProviders: ProviderDeclaration[] = [];
      for (const { id: toolId, options } of toolInstances) {
        allProviders.push(...collectToolProviders(toolId, options));
      }
      providers = mergeProviderDeclarations(allProviders);

      // Collect integrations provider-to-path mapping.
      // When multiple Integrations instances register the same provider
      // (e.g., GoogleCalendar and GoogleContacts both register "google"),
      // prefer the shallowest path since child tools share the parent's auth.
      for (const { path, id: toolId, options } of toolInstances) {
        if (toolId === "Integrations" && (options as any)?.providers) {
          const pathString = path.join(":");
          for (const p of (options as any).providers) {
            if (p.provider) {
              const existing = integrationsMap[p.provider];
              if (!existing || path.length < existing.split(":").length) {
                integrationsMap[p.provider] = pathString;
              }
            }
          }
        }
      }
    } else {
      // RUNTIME: Tools are validated per-path in builtInToolFactory as they're created
      // Use stored permissions without rebuilding twist
      permissions = storedPermissions || {};
    }

    return {
      permissions,
      toolPermissions: toolPermissionsMap,
      providers,
      integrationsMap,
      optionsSchema,
      activate: async (priority: Pick<Priority, "id">, context?: { actor: { id: string; type: number } }) => {
        await env.TWIST_LOGS_QUEUE.send({
          twistRootId: id,
          environment,
          severity: "info",
          message: `Activating in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleTwistOperation(
          "activate",
          () => twist.activate(twistInit, priority, context),
          { env, id, version, environment }
        );
      },

      upgrade: async () => {
        await env.TWIST_LOGS_QUEUE.send({
          twistRootId: id,
          environment,
          severity: "info",
          message: `Upgrading in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleTwistOperation("upgrade", () => twist.upgrade(twistInit), {
          env,
          id,
          version,
          environment,
        });
      },

      deactivate: async () => {
        await env.TWIST_LOGS_QUEUE.send({
          twistRootId: id,
          environment,
          severity: "info",
          message: `Deactivating in ${environment} for priority ${priorityId}`,
          timestamp: Date.now(),
        });

        await handleTwistOperation(
          "deactivate",
          () => twist.deactivate(twistInit),
          { env, id, version, environment }
        );
      },

      dispatch: async (toolName: string, ...args: any[]) => {
        // Find all tool paths that include this tool type
        const toolPaths = Object.keys(
          storedToolPermissions ?? toolPermissionsMap
        ).filter((path) => path.split(":").includes(toolName));

        if (toolPaths.length === 0) {
          return; // No instances of this tool
        }

        const logger = createLogger({ twist_id: id, environment });
        logger.info("Dispatching to twist tool", {
          tool_name: toolName,
        });

        const twistInit = {
          priorityTwistId,
          builtInToolFactory,
        };

        // Convert all paths to arrays
        const pathArrays = toolPaths.map((path) => path.split(":"));

        // Single RPC call with all paths
        await twist.dispatchToTool(twistInit, pathArrays, ...args);
      },

      callCallback: async (
        path: string[],
        functionName: string,
        ...args: any[]
      ) => {
        return await handleTwistOperation(
          functionName,
          // @ts-ignore - Type instantiation is excessively deep and possibly infinite
          () => twist.callCallback(twistInit, path, functionName, ...args),
          { env, id, version, environment }
        );
      },
    };
  };
}
