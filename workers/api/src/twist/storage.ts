import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { type TwistEnvironment, type Bindings } from "../env";
import { twistFactory } from "./factory";

export async function storeTwistModule({
  env,
  ctx,
  id,
  module,
  sourcemap,
  environment,
  db,
  dryRun = false,
}: {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  id: string;
  module: string;
  sourcemap?: string;
  environment: TwistEnvironment;
  db: Kysely<DB>;
  dryRun?: boolean;
}) {
  // Generate timestamp version (or placeholder for dry-run)
  const version = dryRun ? "dry-run" : Date.now().toString();

  // Initialize twist to collect permissions and provider declarations
  const { permissions, toolPermissions, providers, integrationsMap } = await twistFactory({
    env,
    ctx,
    db,
    checkPermissions: false,
    module,
  })({ id, environment, version, priorityId: "", priorityTwistId: "__deployment__" });

  // Only store to R2 and KV if not in dry-run mode
  if (!dryRun) {
    await env.TWIST_MODULES_BUCKET.put(
      `twists/${id}/${version}/modules`,
      module
    );

    // Store sourcemap if provided (for stack trace translation)
    if (sourcemap) {
      await env.TWIST_MODULES_BUCKET.put(
        `twists/${id}/${version}/sourcemaps`,
        sourcemap
      );
    }

    await env.TWIST_CONFIG.put(
      `${id}:${version}`,
      JSON.stringify({ permissions, toolPermissions, providers, integrationsMap })
    );
  }

  return {
    version,
    permissions,
    providers,
    integrationsMap,
  };
}
