import { Hono } from "hono";
import { z } from "zod";

import type { Callback } from "@plotday/twister/tools/callbacks";
import type { AuthProvider } from "@plotday/twister/tools/integrations";

import { Integrations } from "../twist/tools/integrations";
import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";

const authRoutes = new Hono<{ Bindings: Bindings }>();

// Schemas
const AuthUrlRequestSchema = z.object({
  provider: z.string(),
  level: z.string(),
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
      c.env.CALLBACKS,
      c.req.query(),
      c.env
    );
  } catch (error) {
    console.error("Error processing auth callback:", error);
    return new Response("Internal server error", { status: 500 });
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
      return new Response("No client ID configured for this platform", {
        status: 400,
      });
    }

    return c.json(result);
  } catch (error) {
    console.error("Error generating auth URL:", error);
    if (error instanceof Error) {
      return new Response(`Error generating auth URL: ${error.message}`, {
        status: 400,
      });
    }
    return new Response("Internal server error", { status: 500 });
  }
});

export default authRoutes;
