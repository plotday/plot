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

type NeedsReauthEventInput = {
  env: Bindings;
  userId: string;
  twistInstanceId: string;
  provider: string;
  actorId: string;
  // Which code path detected the dead/invalid token and flagged re-auth.
  trigger:
    | "refresh_permanent"
    | "no_refresh_token"
    | "insufficient_scope"
    | "token_missing"
    | "connector_signal";
  // Human-readable reason captured at flag time (usually the raw OAuth error).
  reason: string;
  // RFC 6749 OAuth error code when available (e.g. "invalid_grant").
  oauthError?: string | null;
  // HTTP status from the failed token/refresh call when available.
  status?: number | null;
};

/**
 * Emit a PostHog event when a connection is flagged for re-authentication.
 *
 * `twist_instance_connection` only stores `needs_reauth_at` (a timestamp); the
 * *reason* is otherwise written only to short-retention worker logs, so by the
 * time a user re-auths the "why" is gone (this is exactly what blocked the
 * kris@plot.day Google re-auth investigation — the reason had aged out). This
 * event preserves the reason (trigger + OAuth error + message), attributed to
 * the user, so we can tell after the fact why a connection demanded re-auth.
 *
 * Opens a dedicated PostHog client so it flushes reliably from the background
 * sync/refresh paths where the request-scoped tracker may already be shut down.
 * Never throws — telemetry failures must not look like (or block) the re-auth
 * flag itself.
 */
export async function emitNeedsReauthEvent(
  input: NeedsReauthEventInput,
): Promise<void> {
  if (!input.env.POSTHOG_API_KEY) return;

  try {
    const postHog = new PostHog(input.env.POSTHOG_API_KEY, {
      host: input.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    try {
      postHog.capture({
        distinctId: input.userId,
        event: "connector_needs_reauth",
        properties: {
          provider: input.provider,
          trigger: input.trigger,
          reason: input.reason,
          oauth_error: input.oauthError ?? null,
          status: input.status ?? null,
          twist_instance_id: input.twistInstanceId,
          actor_id: input.actorId,
          api_env: currentEnv(),
        },
      });
    } finally {
      await postHog.shutdown();
    }
  } catch {
    // Best-effort telemetry — swallow so a PostHog hiccup never masks or
    // aborts the needs_reauth flag.
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
