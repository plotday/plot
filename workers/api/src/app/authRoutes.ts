import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";
import type { Callback } from "@plotday/twister/tools/callbacks";
import type { AuthProvider } from "@plotday/twister/tools/integrations";

import type { Bindings } from "../env";
import { Integrations } from "../twist/tools/integrations";
import { captureServerError } from "../utils/error-capture";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
import { handleValidationError } from "../utils/validation";
import { authRateLimiter } from "../middleware/rate-limit";

const authRoutes = new Hono<{ Bindings: Bindings }>();

// Apply strict rate limiting to all auth routes (20 req/min)
authRoutes.use("*", authRateLimiter);

// Schemas
const AuthUrlRequestSchema = z.object({
  provider: z.string(),
  level: z.string(),
  scopes: z.array(z.string()),
  callback: z.string().optional(),
  redirectUri: z.url(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
});

const SendCodeRequestSchema = z.object({
  email: z.string().email(),
});

// POST /auth - Handle OAuth redirects
authRoutes.post("/auth", async (c) => {
  try {
    return await Integrations.HandleOauthCallback(
      c.env.STORAGE,
      c.env.CALLBACKS,
      c.req.query(),
      c.env
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
      level,
      scopes: requestScopes,
      callback,
      redirectUri,
      platform,
    } = parseResult.data;

    // Use the scopes from the request or from query parameters
    const scopesToUse = requestScopes?.length > 0 ? requestScopes : scopes;

    const result = await Integrations.GenerateAuthUrl({
      provider: provider as AuthProvider,
      level: level as any, // AuthLevel type
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

// POST /auth/send-code - Send OTP code via email (public endpoint, no auth required)
// Sends welcome email for new users, password reset for existing users
// Always returns success to prevent account enumeration
authRoutes.post("/auth/send-code", async (c) => {
  try {
    const parseResult = SendCodeRequestSchema.safeParse(await c.req.json());

    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }

    const { email } = parseResult.data;

    // Create admin client to check user existence and send emails
    const supabaseAdmin = createClient(
      c.env.SUPABASE_URL,
      c.env.SUPABASE_SERVICE_KEY
    );

    // Check if user already exists
    const { data: users, error: listError } =
      await supabaseAdmin.auth.admin.listUsers();

    if (listError) {
      const logger = createLogger();
      logger.error("Error checking user existence", new Error(listError.message));
      // Return success anyway to prevent account enumeration
      return c.json({ success: true });
    }

    const existingUser = users.users.find((user) => user.email === email);

    if (existingUser) {
      // User exists - send password reset email (recovery template with OTP)
      const { error: resetError } =
        await supabaseAdmin.auth.resetPasswordForEmail(email);

      if (resetError) {
        const logger = createLogger();
        logger.error("Error sending password reset email", new Error(resetError.message), {
          email,
        });
      }
    } else {
      // New user - send signup OTP email (confirmation template)
      const { error: signupError } = await supabaseAdmin.auth.signInWithOtp({
        email: email,
      });

      if (signupError) {
        const logger = createLogger();
        logger.error("Error sending signup email", new Error(signupError.message), {
          email,
        });
      }
    }

    // Always return success to prevent account enumeration
    return c.json({ success: true });
  } catch (error) {
    const logger = createLogger();
    logger.error("Error in send-code endpoint", error as Error);
    // Return success even on error to prevent account enumeration
    return c.json({ success: true });
  }
});

export default authRoutes;
