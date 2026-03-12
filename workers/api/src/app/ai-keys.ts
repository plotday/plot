import { Hono } from "hono";

import type { Bindings } from "../env";
import { encrypt } from "../utils/encryption";
import { validateAiKey } from "../utils/ai-key-validation";
import { captureServerError } from "../utils/error-capture";

const aiKeys = new Hono<{ Bindings: Bindings }>();

const VALID_PROVIDERS = ["openai", "anthropic", "google"] as const;
type AiProvider = (typeof VALID_PROVIDERS)[number];

function isValidProvider(p: string): p is AiProvider {
  return VALID_PROVIDERS.includes(p as AiProvider);
}

// ---------------------------------------------------------------------------
// User endpoints
// ---------------------------------------------------------------------------

// GET /ai-keys — list user's key metadata
aiKeys.get("/ai-keys", async (c) => {
  const user = c.var.user;

  const keys = await c.var.db
    .selectFrom("ai_key")
    .select(["provider", "key_suffix", "created_at"])
    .where("user_id", "=", user.id)
    .execute();

  return c.json(keys);
});

// POST /ai-keys — add or replace a user key
aiKeys.post("/ai-keys", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ provider: string; key: string }>();

  if (!body.provider || !isValidProvider(body.provider)) {
    return c.json({ error: "Invalid provider. Must be one of: openai, anthropic, google" }, 400);
  }
  if (!body.key?.trim()) {
    return c.json({ error: "API key is required" }, 400);
  }

  const key = body.key.trim();
  const provider = body.provider;

  // Validate key with provider
  const validation = await validateAiKey(provider, key);
  if (!validation.valid) {
    return c.json({ error: validation.error ?? "Invalid API key" }, 400);
  }

  try {
    const { ciphertext, iv } = await encrypt(key, c.env.AI_KEY_ENCRYPTION_KEY);
    const keySuffix = key.slice(-4);

    await c.var.db
      .insertInto("ai_key")
      .values({
        user_id: user.id,
        provider: provider as any,
        encrypted_key: ciphertext,
        key_suffix: keySuffix,
        iv,
      })
      .onConflict((oc) =>
        oc
          .columns(["user_id", "provider"])
          .where("user_id", "is not", null)
          .doUpdateSet({
            encrypted_key: ciphertext,
            key_suffix: keySuffix,
            iv,
          })
      )
      .execute();

    return c.json({
      provider,
      key_suffix: keySuffix,
      ...(validation.error ? { warning: validation.error } : {}),
    });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI key");
  }
});

// DELETE /ai-keys/:provider — remove user's key for a provider
aiKeys.delete("/ai-keys/:provider", async (c) => {
  const user = c.var.user;
  const provider = c.req.param("provider");

  if (!isValidProvider(provider)) {
    return c.json({ error: "Invalid provider" }, 400);
  }

  await c.var.db
    .deleteFrom("ai_key")
    .where("user_id", "=", user.id)
    .where("provider", "=", provider as any)
    .execute();

  return c.json({ success: true });
});

// ---------------------------------------------------------------------------
// Org admin endpoints
// ---------------------------------------------------------------------------

async function requireOrgAdmin(c: any, orgId: string) {
  const user = c.var.user;
  const member = await c.var.db
    .selectFrom("organization_member")
    .select(["id", "role"])
    .where("organization_id", "=", orgId as any)
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!member || member.role !== "admin") {
    return null;
  }
  return member;
}

// GET /organization/:id/ai-keys — list org's key metadata
aiKeys.get("/organization/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const keys = await c.var.db
    .selectFrom("ai_key")
    .select(["provider", "key_suffix", "created_at"])
    .where("organization_id", "=", orgId as any)
    .execute();

  return c.json(keys);
});

// POST /organization/:id/ai-keys — add or replace an org key
aiKeys.post("/organization/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ provider: string; key: string }>();

  if (!body.provider || !isValidProvider(body.provider)) {
    return c.json({ error: "Invalid provider. Must be one of: openai, anthropic, google" }, 400);
  }
  if (!body.key?.trim()) {
    return c.json({ error: "API key is required" }, 400);
  }

  const key = body.key.trim();
  const provider = body.provider;

  const validation = await validateAiKey(provider, key);
  if (!validation.valid) {
    return c.json({ error: validation.error ?? "Invalid API key" }, 400);
  }

  try {
    const { ciphertext, iv } = await encrypt(key, c.env.AI_KEY_ENCRYPTION_KEY);
    const keySuffix = key.slice(-4);

    await c.var.db
      .insertInto("ai_key")
      .values({
        organization_id: orgId as any,
        provider: provider as any,
        encrypted_key: ciphertext,
        key_suffix: keySuffix,
        iv,
      })
      .onConflict((oc) =>
        oc
          .columns(["organization_id", "provider"])
          .where("organization_id", "is not", null)
          .doUpdateSet({
            encrypted_key: ciphertext,
            key_suffix: keySuffix,
            iv,
          })
      )
      .execute();

    return c.json({
      provider,
      key_suffix: keySuffix,
      ...(validation.error ? { warning: validation.error } : {}),
    });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI key");
  }
});

// DELETE /organization/:id/ai-keys/:provider — remove org key
aiKeys.delete("/organization/:id/ai-keys/:provider", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const provider = c.req.param("provider");
  if (!isValidProvider(provider)) {
    return c.json({ error: "Invalid provider" }, 400);
  }

  await c.var.db
    .deleteFrom("ai_key")
    .where("organization_id", "=", orgId as any)
    .where("provider", "=", provider as any)
    .execute();

  return c.json({ success: true });
});

export default aiKeys;
