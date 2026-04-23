import { PostHog } from "posthog-node";

import type { Bindings } from "../env";

// Populated by the Wrangler `define` for each env (development | production).
// Read via `typeof` so unit tests without the build-time define don't crash.
declare const ENV: string;

function currentEnv(): string {
  return typeof ENV !== "undefined" ? ENV : "unknown";
}

type DeploymentEventInput = {
  env: Bindings;
  userId: string | null | undefined;
  publisherId: number | null | undefined;
  twistPackageId: string;
  name: string;
  version: string;
  environment: "personal" | "private" | "review" | "public";
  // Whether this deploy created a new twist row (vs updating an existing one).
  isFirstDeploy: boolean;
  // Connector vs twist — mirrors the `twist.is_source` column.
  isSource: boolean;
  // Shape of the request payload: pre-bundled JS (`module`) or raw files
  // (`source`) that were built in the sandbox.
  deploymentType: "module" | "source";
  // How the user authored the twist: hand-written code or generated from a
  // natural-language spec via `/twist/generate`. "code" is the default.
  source: "code" | "spec";
};

/**
 * Emit a PostHog event for a successful custom twist/connector deployment.
 *
 * Opens a dedicated PostHog client (rather than reusing the request-scoped
 * tracker) so the event flushes reliably from the SSE/background-deploy path,
 * where the request tracker may be shut down before the deployment finishes.
 */
export async function emitCustomDeploymentEvent(
  input: DeploymentEventInput,
): Promise<void> {
  if (!input.env.POSTHOG_API_KEY) return;

  const distinctId = input.userId ?? "$anonymous";
  const event = input.isSource
    ? "custom_connector_deployed"
    : "custom_twist_deployed";

  const postHog = new PostHog(input.env.POSTHOG_API_KEY, {
    host: input.env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
  });
  try {
    postHog.capture({
      distinctId,
      event,
      properties: {
        twist_package_id: input.twistPackageId,
        name: input.name,
        version: input.version,
        environment: input.environment,
        publisher_id: input.publisherId ?? null,
        is_first_deploy: input.isFirstDeploy,
        is_source: input.isSource,
        deployment_type: input.deploymentType,
        source: input.source,
        api_env: currentEnv(),
      },
    });
  } finally {
    await postHog.shutdown();
  }
}

type GenerationFailureInput = {
  env: Bindings;
  userId: string | null | undefined;
  error: unknown;
  specLength: number;
  attempt?: number;
};

/**
 * Capture a spec→twist generation failure in PostHog error tracking.
 *
 * Used by `generateTwist` so every failure (missing config, bad model output,
 * exhausted retries) surfaces as a PostHog exception we can investigate.
 */
export async function captureGenerationFailure(
  input: GenerationFailureInput,
): Promise<void> {
  if (!input.env.POSTHOG_API_KEY) return;

  const err =
    input.error instanceof Error
      ? input.error
      : new Error(String(input.error ?? "Unknown twist generation error"));

  const postHog = new PostHog(input.env.POSTHOG_API_KEY, {
    host: input.env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
  });
  try {
    postHog.captureException(err, input.userId ?? undefined, {
      context: "twist:generate",
      spec_length: input.specLength,
      attempt: input.attempt ?? null,
      api_env: currentEnv(),
    });
  } finally {
    await postHog.shutdown();
  }
}
