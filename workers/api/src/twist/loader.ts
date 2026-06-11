import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { type Bindings, type TwistEnvironment } from "../env";
import { type CallbacksState } from "../state/callbacks";
import { type LogSubscriptions } from "../state/log-subscriptions";
import { type Storage } from "../state/storage";
import TwistEntrypoint from "./entrypoint";

export async function getTwist({
  env,
  ctx,
  db,
  id: providedId,
  environment: providedEnvironment,
  version,
  twistInstanceId,
  storage: _storage,
  callbacks: _callbacks,
  logSubscriptions: _logSubscriptions,
  module: providedModule,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  id?: string;
  environment?: TwistEnvironment;
  version?: string;
  twistInstanceId: string;
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
    // Runtime mode: look up from twistInstanceId
    // Get twist_id from twist_instance
    const twistInstanceData = await db
      .selectFrom("twist_instance")
      .select("twist_id")
      .where("id", "=", twistInstanceId)
      .executeTakeFirst();

    if (!twistInstanceData) {
      throw new Error(
        `Failed to fetch twist_instance: No data found`
      );
    }

    const twistId = twistInstanceData.twist_id;

    const twistData = await db
      .selectFrom("twist")
      .select(["version", "twist_package_id", "environment"])
      .where("id", "=", twistId)
      .executeTakeFirst();

    if (!twistData) {
      throw new Error(
        `Failed to fetch twist metadata for twist_id ${twistId}: No data found`
      );
    }

    version ??= twistData.version;
    environment = twistData.environment;
    id = twistData.twist_package_id;
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
        getSourceMetadata: async () => null,
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
      id,
      environment,
    };
  }

  // Use twistId instead of twistInstanceId to share workers across twist_instance instances
  // twistInstanceId is passed per-invocation via twistInit context
  const moduleId = `${id}-${version}`;

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
        console.error(
          "Module not found in R2:",
          `twists/${id}/${version}/modules`
        );
        throw new Error(`Twist module not found: ${id}:${version}`);
      }
      module = moduleFromR2;
    }
    // `ctx.exports` is typed as `Cloudflare.Exports` — a mapped type over the
    // worker's own module exports (`typeof import("./index")`). Resolving it
    // here is circular (index.ts re-exports this loader, which references
    // ctx.exports), so it collapses to `{}` and the exported entrypoints aren't
    // visible. Cast to the loopback-binding factories we actually call; each
    // returns a Fetcher, which is what globalOutbound/tails expect.
    const workerExports = ctx.exports as unknown as {
      HttpProxy: (config: { props: { allowedPatterns: string[] } }) => Fetcher;
      TwistTail: (config: {
        env: { TWIST_LOGS_QUEUE: typeof env.TWIST_LOGS_QUEUE; USAGE: typeof env.USAGE };
        props: { twistRootId: string; environment: TwistEnvironment };
      }) => Fetcher;
    };
    return {
      compatibilityDate: "2025-10-01",
      compatibilityFlags: ["nodejs_compat"],
      mainModule: "index.js",
      modules: {
        "index.js": TwistEntrypoint.Module,
        "twist.js": module,
      },
      globalOutbound: workerExports.HttpProxy({
        props: { allowedPatterns: httpPermissions },
      }),
      tails: [
        workerExports.TwistTail({
          env: {
            TWIST_LOGS_QUEUE: env.TWIST_LOGS_QUEUE,
            USAGE: env.USAGE,
          },
          props: {
            twistRootId: id,
            environment,
            // twistInstanceId removed - now extracted from per-invocation logs
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
