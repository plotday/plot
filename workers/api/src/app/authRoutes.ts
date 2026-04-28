import { Hono } from "hono";
import { z } from "zod";

import type { Callback } from "@plotday/twister/tools/callbacks";
import type { AuthProvider } from "@plotday/twister/tools/integrations";

import type { Bindings } from "../env";
import { Integrations } from "../twist/tools/integrations";
import { captureServerError } from "../utils/error-capture";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { authRateLimiter } from "../middleware/rate-limit";

const authRoutes = new Hono<{ Bindings: Bindings }>();

// Apply strict rate limiting to auth routes only (20 req/min)
// Must scope to "/auth" — using "*" would match ALL /app/* requests
// since this sub-app is mounted at "/" within appSection.
authRoutes.use("/auth", authRateLimiter);

// Schemas
const AuthUrlRequestSchema = z.object({
  provider: z.string(),
  scopes: z.array(z.string()),
  callback: z.string().optional(),
  redirectUri: z.url(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
});

// POST /auth - Handle OAuth redirects
authRoutes.post("/auth", async (c) => {
  try {
    return await Integrations.HandleOauthCallback(
      c.env.STORAGE,
      c.req.query(),
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] }
    );
  } catch (error) {
    return captureServerError(c, error, "Internal server error");
  }
});

// GET /auth - Generate platform-specific auth URLs
authRoutes.get("/auth", async (c) => {
  try {
    // Use queries() to handle array parameters like scopes correctly
    const { scopes } = c.req.queries();
    const parseResult = AuthUrlRequestSchema.safeParse({
      ...c.req.query(),
      ...(scopes ? { scopes } : {}),
    });

    if (!parseResult.success) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Auth URL request validation failed", {
        validation_error: parseResult.error,
      });
      return handleValidationError(parseResult.error);
    }

    const {
      provider,
      scopes: requestScopes,
      callback,
      redirectUri,
      platform,
    } = parseResult.data;

    // Use the scopes from the request or from query parameters
    const scopesToUse = requestScopes?.length > 0 ? requestScopes : scopes;

    const result = await Integrations.GenerateAuthUrl({
      provider: provider as AuthProvider,
      scopes: scopesToUse,
      callback: callback as Callback | undefined,
      redirectUri,
      platform,
      env: c.env,
      storage: c.env.STORAGE, // DurableObject namespace for global storage
    });

    if (!result) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("No client ID configured", {
        provider,
        platform,
        env_keys: Object.keys(c.env).filter((k) => k.includes("AUTH")),
      });
      return c.json(
        { message: "No client ID configured for this platform" },
        400
      );
    }

    return c.json(result);
  } catch (error) {
    if (error instanceof Error) {
      return c.json(
        { message: `Error generating auth URL: ${error.message}` },
        400
      );
    }
    return captureServerError(c, error, "Internal server error");
  }
});

export default authRoutes;
