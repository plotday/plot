import { rateLimiter } from "hono-rate-limiter";
import { WorkersKVStore } from "@hono-rate-limiter/cloudflare";
import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";
import { createLogger } from "../utils/logger";
import { extractRequestContext } from "../utils/log-context";

/**
 * Rate limiting middleware using Cloudflare KV for distributed rate limiting
 *
 * This provides DoS protection and prevents abuse of API endpoints by limiting
 * the number of requests per client within a time window.
 */

/**
 * General rate limiter for most endpoints
 * Allows 100 requests per minute per IP
 */
export const generalRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> = (
  c,
  next
) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 1000, // 1 minute
    limit: 100, // Limit each IP to 100 requests per minute
    standardHeaders: "draft-6", // Set RateLimit-* headers
    keyGenerator: (c) => {
      // Use Cloudflare's connecting IP header
      return c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      const ip = c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";

      logger.warn("General rate limit exceeded", { ip, ...context });
      c.var.postHog?.captureException(
        new Error("General rate limit exceeded"),
        undefined,
        {
          ...context,
          ip,
          limiter_type: "general",
          limit: 100,
          window_ms: 60000,
        }
      );

      return c.json(
        {
          error: "Too many requests. Please try again later.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};

/**
 * Strict rate limiter for authentication endpoints
 * Allows 20 requests per minute per IP to prevent brute force attacks
 */
export const authRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> = (
  c,
  next
) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 1000, // 1 minute
    limit: 20, // Limit each IP to 20 requests per minute
    standardHeaders: "draft-6",
    keyGenerator: (c) => {
      return c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      const ip = c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";

      logger.warn("Auth rate limit exceeded", { ip, ...context });
      c.var.postHog?.captureException(
        new Error("Auth rate limit exceeded"),
        undefined,
        {
          ...context,
          ip,
          limiter_type: "auth",
          limit: 20,
          window_ms: 60000,
        }
      );

      return c.json(
        {
          error: "Too many authentication attempts. Please try again later.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};

/**
 * Very strict rate limiter for token creation endpoints
 * Allows 10 requests per hour per IP to prevent token farming
 */
export const tokenCreationRateLimiter: MiddlewareHandler<{
  Bindings: Bindings;
}> = (c, next) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 60 * 1000, // 1 hour
    limit: 10, // Limit each IP to 10 token creations per hour
    standardHeaders: "draft-6",
    keyGenerator: (c) => {
      return c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      const ip = c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";

      logger.warn("Token creation rate limit exceeded", { ip, ...context });
      c.var.postHog?.captureException(
        new Error("Token creation rate limit exceeded"),
        undefined,
        {
          ...context,
          ip,
          limiter_type: "token_creation",
          limit: 10,
          window_ms: 3600000,
        }
      );

      return c.json(
        {
          error: "Too many token creation requests. Please try again later.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};

/**
 * Moderate rate limiter for webhook endpoints
 * Allows 300 requests per minute per IP (higher because webhooks can be frequent)
 */
export const webhookRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> = (
  c,
  next
) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 1000, // 1 minute
    limit: 300, // Limit each IP to 300 requests per minute
    standardHeaders: "draft-6",
    keyGenerator: (c) => {
      return c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      const ip = c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";

      logger.warn("Webhook rate limit exceeded", { ip, ...context });
      c.var.postHog?.captureException(
        new Error("Webhook rate limit exceeded"),
        undefined,
        {
          ...context,
          ip,
          limiter_type: "webhook",
          limit: 300,
          window_ms: 60000,
        }
      );

      return c.json(
        {
          error: "Too many webhook requests. Please slow down.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};

/**
 * Strict rate limiter for sync/database webhooks
 * Allows 200 requests per minute to prevent queue flooding
 */
export const syncRateLimiter: MiddlewareHandler<{ Bindings: Bindings }> = (
  c,
  next
) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 1000, // 1 minute
    limit: 200, // Limit to 200 database updates per minute
    standardHeaders: "draft-6",
    keyGenerator: (c) => {
      // For sync endpoints, we might want to use a different key
      // Could be based on signature or a fixed key since it's internal
      return "database-sync";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);

      logger.warn("Sync rate limit exceeded - possible queue flooding attack", context);
      c.var.postHog?.captureException(
        new Error("Sync rate limit exceeded"),
        undefined,
        {
          ...context,
          limiter_type: "sync",
          limit: 200,
          window_ms: 60000,
          warning: "possible_queue_flooding_attack",
        }
      );

      return c.json(
        {
          error: "Too many database sync requests. System is under high load.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};

/**
 * Moderate rate limiter for deployment endpoints
 * Allows 30 deployments per hour per IP
 */
export const deploymentRateLimiter: MiddlewareHandler<{
  Bindings: Bindings;
}> = (c, next) => {
  return rateLimiter<{ Bindings: Bindings }>({
    windowMs: 60 * 60 * 1000, // 1 hour
    limit: 30, // Limit each IP to 30 deployments per hour
    standardHeaders: "draft-6",
    keyGenerator: (c) => {
      return c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";
    },
    store: new WorkersKVStore({ namespace: c.env.TWIST_CONFIG }),
    handler: (c) => {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      const ip = c.req.header("CF-Connecting-IP") || c.req.header("x-real-ip") || "unknown";

      logger.warn("Deployment rate limit exceeded", { ip, ...context });
      c.var.postHog?.captureException(
        new Error("Deployment rate limit exceeded"),
        undefined,
        {
          ...context,
          ip,
          limiter_type: "deployment",
          limit: 30,
          window_ms: 3600000,
        }
      );

      return c.json(
        {
          error: "Too many deployment requests. Please try again later.",
          retryAfter: c.res.headers.get("RateLimit-Reset"),
        },
        429
      );
    },
  })(c, next);
};
