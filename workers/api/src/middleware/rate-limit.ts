import { cloudflareRateLimiter } from "@hono-rate-limiter/cloudflare";
import type { MiddlewareHandler } from "hono";

import type { Bindings } from "../env";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";

/**
 * Rate limiting middleware using Cloudflare's native Rate Limiting API
 *
 * Benefits over KV-based approach:
 * - No network latency (counters cached on Worker machine)
 * - Eventually consistent but much faster
 * - Native integration with Cloudflare Workers
 * - No separate storage costs
 *
 * Note: Native API only supports 10s or 60s periods, not hours.
 * This required adjusting token creation (2/min vs 10/hour) and
 * deployment (2/min vs 30/hour) limits.
 */

/**
 * Helper to extract rate limit key based on authentication context.
 * For authenticated endpoints, use user/publisher ID from context.
 * For unauthenticated endpoints, use CF-Connecting-IP.
 */
const getAuthKey = (c: any): string => {
  // Try to get user ID from context (set by auth middleware)
  const userId = c.var.user?.id;
  if (userId) {
    return userId;
  }

  // Try to get publisher ID from context
  const publisherId = c.var.publisher?.id;
  if (publisherId) {
    return `publisher:${publisherId}`;
  }

  // Fallback to IP address
  return (
    c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown"
  );
};

/**
 * Helper to extract rate limit key from the bearer token directly.
 * Use this when the rate limiter runs BEFORE auth middleware (e.g. SDK section),
 * since c.var.user/publisher won't be set yet. The token value itself is unique
 * per user/publisher, so it works as an identity key.
 */
const getBearerTokenKey = (c: any): string => {
  const authHeader = c.req.header("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    return `token:${authHeader.slice(7)}`;
  }
  return (
    c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown"
  );
};

/**
 * Helper to create custom handler for logging and telemetry
 */
const createRateLimitHandler = (
  limiterType: string,
  limit: number,
  period: number
): MiddlewareHandler<{ Bindings: Bindings }> => {
  return async (c) => {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    const ip =
      c.req.header("CF-Connecting-IP") ||
      c.req.header("x-real-ip") ||
      "unknown";

    logger.warn(`${limiterType} rate limit exceeded`, { ip, ...context });
    c.var.tracker?.capture(`rate_limit_exceeded`, {
      ...context,
      ip,
      limiter_type: limiterType,
      limit,
      period,
    });

    return c.json(
      {
        error: getErrorMessage(limiterType),
      },
      429,
      { "Retry-After": "5" }
    );
  };
};

/**
 * Get user-friendly error message for each rate limiter type
 */
const getErrorMessage = (type: string): string => {
  switch (type) {
    case "general":
      return "Too many requests. Please try again later.";
    case "auth":
      return "Too many authentication attempts. Please try again later.";
    case "token_creation":
      return "Too many token creation requests. Please try again later.";
    case "webhook":
      return "Too many webhook requests. Please slow down.";
    case "sync":
      return "Too many database sync requests. System is under high load.";
    case "app_sync":
      return "Too many sync requests. Please try again shortly.";
    case "deployment":
      return "Too many deployment requests. Please try again later.";
    case "sdk":
      return "Too many SDK requests. Please try again later.";
    default:
      return "Rate limit exceeded.";
  }
};

/**
 * General rate limiter for most endpoints
 * 100 requests per minute
 *
 * Applied globally before authentication, so uses IP-based limiting
 */
export const generalRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  cloudflareRateLimiter<{ Bindings: Bindings }>({
    rateLimitBinding: (c) => c.env.GENERAL_RATE_LIMITER,
    keyGenerator: (c) =>
      c.req.header("CF-Connecting-IP") ||
      c.req.header("x-real-ip") ||
      "unknown",
    handler: createRateLimitHandler("general", 100, 60),
  });

/**
 * Strict rate limiter for authentication endpoints
 * 20 requests per minute
 *
 * Auth endpoints are unauthenticated by nature, so uses IP-based limiting
 */
export const authRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  cloudflareRateLimiter<{ Bindings: Bindings }>({
    rateLimitBinding: (c) => c.env.AUTH_RATE_LIMITER,
    keyGenerator: (c) =>
      c.req.header("CF-Connecting-IP") ||
      c.req.header("x-real-ip") ||
      "unknown",
    handler: createRateLimitHandler("auth", 20, 60),
  });

/**
 * Very strict rate limiter for token creation endpoints
 * 2 requests per minute (allows small bursts, ~120/hour max)
 *
 * NOTE: Changed from 10/hour to 2/min due to Cloudflare API period limitations
 * (periods must be 10s or 60s, cannot use 1-hour windows)
 *
 * Applied after SDK auth middleware, so uses user ID for rate limiting
 */
export const tokenCreationRateLimiter: MiddlewareHandler<{
  Bindings: Bindings;
}> = cloudflareRateLimiter<{ Bindings: Bindings }>({
  rateLimitBinding: (c) => c.env.TOKEN_RATE_LIMITER,
  keyGenerator: getAuthKey,
  handler: createRateLimitHandler("token_creation", 2, 60),
});

/**
 * Moderate rate limiter for webhook endpoints
 * 300 requests per minute
 *
 * Uses per-webhook limiting based on route parameters when available:
 * - Gmail webhooks: Limited per topicId
 * - Slack webhooks: Limited per IP (no identifier in path)
 */
export const webhookRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  cloudflareRateLimiter<{ Bindings: Bindings }>({
    rateLimitBinding: (c) => c.env.WEBHOOK_RATE_LIMITER,
    keyGenerator: (c) => {
      // Extract topic ID for Gmail webhooks (format: /hook/gmail/:topicId)
      const topicId = c.req.param("topicId");
      if (topicId) {
        return `webhook:${topicId}`;
      }

      // Fallback to IP for webhooks without identifiers (e.g., Slack)
      return (
        c.req.header("CF-Connecting-IP") ||
        c.req.header("x-real-ip") ||
        "unknown"
      );
    },
    handler: createRateLimitHandler("webhook", 300, 60),
  });

/**
 * Per-user rate limiter for app sync endpoints
 * 300 requests per minute per user
 *
 * Applied after auth middleware so user ID is available for keying.
 * Allows ~4 full syncs per minute comfortably (each ~14-18 calls).
 * Per-user keying means multiple users behind the same NAT won't interfere.
 */
export const appSyncRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  cloudflareRateLimiter<{ Bindings: Bindings }>({
    rateLimitBinding: (c) => c.env.APP_SYNC_RATE_LIMITER,
    keyGenerator: getAuthKey,
    handler: createRateLimitHandler("app_sync", 300, 60),
  });

/**
 * Strict rate limiter for sync/database webhooks
 * 200 requests per minute
 *
 * Uses global limit (fixed key) to prevent queue flooding
 */
export const syncRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  cloudflareRateLimiter<{ Bindings: Bindings }>({
    rateLimitBinding: (c) => c.env.SYNC_RATE_LIMITER,
    keyGenerator: () => "database-sync", // Fixed key for global limit
    handler: createRateLimitHandler("sync", 200, 60),
  });

/**
 * Per-identity rate limiter for SDK endpoints (CLI calls)
 * 500 requests per minute per authenticated user/publisher
 *
 * Replaces the IP-based generalRateLimiter on the SDK section because
 * GitHub Actions runners share IP ranges, causing CI/CD deployments of
 * many twists to hit the shared IP bucket. Uses the bearer token as key
 * since this middleware runs BEFORE sdkAuthMiddleware.
 *
 * Wrapped with error handling: if the rate limit binding errors, the
 * request proceeds without rate limiting rather than returning 500.
 */
const _sdkRateLimiter = cloudflareRateLimiter<{ Bindings: Bindings }>({
  rateLimitBinding: (c) => c.env.SDK_RATE_LIMITER,
  keyGenerator: getBearerTokenKey,
  handler: createRateLimitHandler("sdk", 500, 60),
});

export const sdkRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  async (c, next) => {
    try {
      return await _sdkRateLimiter(c, next);
    } catch (error) {
      const logger = createLogger();
      logger.error("SDK rate limiter error, allowing request", error as Error);
      c.var.tracker?.captureException(
        error instanceof Error
          ? error
          : new Error(`SDK rate limiter error: ${error}`),
        { path: c.req.path }
      );
      return next();
    }
  };

/**
 * Moderate rate limiter for deployment endpoints
 * 10 requests per minute per user per twist
 *
 * NOTE: Changed from 30/hour to 2/min due to Cloudflare API period limitations
 *
 * Uses composite key of user/publisher ID + package ID to allow:
 * - CI/CD to deploy multiple different twists without hitting global limit
 * - Each user-twist pair to have independent quota
 *
 * This runs as route-level middleware AFTER sdkAuthMiddleware,
 * so c.var.user/publisher are available.
 *
 * Wrapped with error handling to prevent binding errors from causing 500s.
 */
const _deploymentRateLimiter = cloudflareRateLimiter<{ Bindings: Bindings }>({
  rateLimitBinding: (c) => c.env.DEPLOYMENT_RATE_LIMITER,
  keyGenerator: (c) => {
    // Get user or publisher ID (authenticated endpoint)
    const userId = c.var.user?.id;
    const publisherId = c.var.publisher?.id;
    const authId =
      userId || (publisherId ? `publisher:${publisherId}` : null);

    // Get package ID from URL parameter
    const packageId = c.req.param("id");

    // Create composite key for per-user-per-twist limiting
    if (authId && packageId) {
      return `${authId}:${packageId}`;
    }

    // Fallback to just auth ID if no package ID
    if (authId) {
      return authId;
    }

    // Final fallback to IP (should not happen for authenticated endpoints)
    return (
      c.req.header("CF-Connecting-IP") ||
      c.req.header("x-real-ip") ||
      "unknown"
    );
  },
  handler: createRateLimitHandler("deployment", 10, 60),
});

export const deploymentRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> =
  async (c, next) => {
    try {
      return await _deploymentRateLimiter(c, next);
    } catch (error) {
      const logger = createLogger();
      logger.error(
        "Deployment rate limiter error, allowing request",
        error as Error
      );
      c.var.tracker?.captureException(
        error instanceof Error
          ? error
          : new Error(`Deployment rate limiter error: ${error}`),
        { path: c.req.path }
      );
      return next();
    }
  };
