import { type SupabaseClient } from "@plotday/db";

import { type TwistEnvironment, type Bindings } from "../env";
import { type CallbacksState } from "../state/callbacks";
import { type LogSubscriptions } from "../state/log-subscriptions";
import { type Storage } from "../state/storage";
import TwistEntrypoint from "./entrypoint";

export async function getTwist({
  env,
  ctx,
  supabase,
  id: providedId,
  environment: providedEnvironment,
  version,
  priorityId: _priorityId,
  priorityTwistId,
  storage: _storage,
  callbacks: _callbacks,
  logSubscriptions: _logSubscriptions,
  module: providedModule,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  supabase: SupabaseClient;
  id?: string;
  environment?: TwistEnvironment;
  version?: string;
  priorityId: string;
  priorityTwistId: string;
  storage: DurableObjectNamespace<Storage>;
  callbacks: DurableObjectNamespace<CallbacksState>;
  logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
  module?: string;
}) {
  let id: string;
  let environment: TwistEnvironment;

  // If id and environment are provided, use them (deployment mode)
  if (providedId && providedEnvironment) {
    id = providedId;
    environment = providedEnvironment;
  } else {
    // Runtime mode: look up from priorityTwistId
    // Get twist_id from priority_twist
    const { data: priorityTwistData, error: priorityTwistError } = await supabase
      .from("priority_twist")
      .select("twist_id")
      .eq("id", priorityTwistId)
      .single();

    if (priorityTwistError || !priorityTwistData) {
      throw new Error(
        `Failed to fetch priority_twist: ${
          priorityTwistError?.message || "No data found"
        }`
      );
    }

    const twistId = priorityTwistData.twist_id;

    // Get twist metadata and twist_admin_id
    const { data: twistData, error: twistError } = await supabase
      .from("twist")
      .select("version,twist_admin_id,environment")
      .eq("id", twistId)
      .single();

    if (twistError || !twistData) {
      throw new Error(
        `Failed to fetch twist metadata for twist_id ${twistId}: ${
          twistError?.message || "No data found"
        }`
      );
    }

    version ??= twistData.version;
    environment = twistData.environment;

    // Get twist_package_id for R2 module loading
    const { data: adminData, error: adminError } = await supabase
      .from("twist_admin")
      .select("twist_package_id")
      .eq("id", twistData.twist_admin_id)
      .single();

    if (adminError || !adminData) {
      throw new Error(
        `Failed to fetch twist_package_id: ${
          adminError?.message || "No data found"
        }`
      );
    }

    id = adminData.twist_package_id;
  }

  // TypeScript check: ensure id and environment are defined
  if (!id || !environment) {
    throw new Error("Failed to determine twist id and environment");
  }

  const config = await env.TWIST_CONFIG.get(`${id}:${version}`);
  let httpPermissions = ["*"];
  if (config) {
    const parsed = JSON.parse(config);
    const permissions = parsed?.permissions;
    if (permissions) {
      // Extract network URLs for HttpProxy from permissions
      const networkPerms = permissions["network"] as
        | Record<string, string[]>
        | undefined;
      httpPermissions = networkPerms ? Object.keys(networkPerms) : [];
    }
  }

  // If module is provided directly (e.g., in tests), use it without LOADER
  if (providedModule && !env.LOADER) {
    // Create a mock worker instance for tests
    const mockWorker = {
      getEntrypoint: () => ({
        // Return mock entrypoint with all required methods
        init: async () => {},
        activate: async () => {},
        deactivate: async () => {},
        upgrade: async () => {},
        dispatch: async () => {},
        callCallback: async () => {},
        collectToolPermissions: () => ({
          toolPermissions: {},
          permissions: {},
        }),
      }),
    };
    return {
      twist: mockWorker.getEntrypoint() as any,
      version,
    };
  }

  const moduleId = `${priorityTwistId}-${version}`;
  const worker = env.LOADER.get(moduleId, async () => {
    // Use provided module or load from R2
    let module: string;
    if (providedModule) {
      module = providedModule;
    } else {
      const moduleFromR2 = await (
        await env.TWIST_MODULES_BUCKET.get(`twists/${id}/${version}/modules`)
      )?.text();
      if (!moduleFromR2) {
        throw new Error(`Twist module not found: ${id}:${version}`);
      }
      module = moduleFromR2;
    }
    return {
      compatibilityDate: "2025-10-01",
      compatibilityFlags: ["nodejs_compat"],
      mainModule: "index.js",
      modules: {
        "index.js": TwistEntrypoint.Module,
        "twist.js": module,
      },
      globalOutbound: ctx.exports.HttpProxy({
        props: { allowedPatterns: httpPermissions },
      }),
      tails: [
        ctx.exports.TwistTail({
          env: {
            TWIST_LOGS_QUEUE: env.TWIST_LOGS_QUEUE,
            USAGE: env.USAGE,
          },
          props: {
            twistRootId: id,
            environment,
            priorityTwistId,
          },
        }),
      ],
    };
  });

  return {
    twist: worker.getEntrypoint<TwistEntrypoint>(),
    version,
    id: id as string,
    environment: environment as TwistEnvironment,
  };
}
