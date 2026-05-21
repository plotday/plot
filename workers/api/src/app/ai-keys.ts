import { Hono } from "hono";

import type { Bindings } from "../env";
import { encrypt } from "../utils/encryption";
import { validateAiKey } from "../utils/ai-key-validation";
import { captureServerError } from "../utils/error-capture";

const aiKeys = new Hono<{ Bindings: Bindings }>();

const VALID_PROVIDERS = ["openai", "anthropic", "google", "custom"] as const;
type AiProvider = (typeof VALID_PROVIDERS)[number];

function isValidProvider(p: string): p is AiProvider {
  return VALID_PROVIDERS.includes(p as AiProvider);
}

type AiKeyBody = {
  provider: string;
  key: string;
  name?: string;
  customBaseUrl?: string;
  fastModel?: string;
  thinkingModel?: string;
};

function validateBody(body: AiKeyBody): string | null {
  if (!body.provider || !isValidProvider(body.provider)) {
    return "Invalid provider. Must be one of: openai, anthropic, google, custom";
  }
  if (!body.key?.trim()) {
    return "API key is required";
  }
  if (body.provider === "custom") {
    if (!body.name?.trim()) return "Name is required for custom providers";
    if (!body.customBaseUrl?.trim()) return "Base URL is required for custom providers";
    if (!body.fastModel?.trim()) return "Fast model name is required for custom providers";
    if (!body.thinkingModel?.trim()) return "Thinking model name is required for custom providers";
  }
  return null;
}

// ---------------------------------------------------------------------------
// User endpoints
// ---------------------------------------------------------------------------

// GET /ai-keys — list user's key metadata
aiKeys.get("/ai-keys", async (c) => {
  const user = c.var.user;

  const keys = await c.var.db
    .selectFrom("ai_key")
    .select(["id", "provider", "name", "key_suffix", "custom_base_url", "fast_model", "thinking_model", "created_at"])
    .where("user_id", "=", user.id)
    .execute();

  return c.json(keys);
});

// POST /ai-keys — add or replace a user key
aiKeys.post("/ai-keys", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<AiKeyBody>();

  const error = validateBody(body);
  if (error) return c.json({ error }, 400);

  const key = body.key.trim();
  const provider = body.provider as AiProvider;

  // Validate key with provider
  const validation = await validateAiKey(
    provider,
    key,
    provider === "custom" ? body.customBaseUrl!.trim() : undefined
  );
  if (!validation.valid) {
    return c.json({ error: validation.error ?? "Invalid API key" }, 400);
  }

  try {
    const { ciphertext, iv } = await encrypt(key, c.env.AI_KEY_ENCRYPTION_KEY);
    const keySuffix = key.slice(-4);

    const values: any = {
      user_id: user.id,
      provider: provider as any,
      encrypted_key: ciphertext,
      key_suffix: keySuffix,
      iv,
    };

    if (provider === "custom") {
      values.name = body.name!.trim();
      values.custom_base_url = body.customBaseUrl!.trim().replace(/\/+$/, "");
      values.fast_model = body.fastModel!.trim();
      values.thinking_model = body.thinkingModel!.trim();
    }

    if (provider === "custom") {
      // For custom providers, check name uniqueness manually then insert
      const existing = await c.var.db
        .selectFrom("ai_key")
        .select("id")
        .where("user_id", "=", user.id)
        .where("provider", "=", "custom" as any)
        .where("name", "=", values.name)
        .executeTakeFirst();

      if (existing) {
        // Update existing custom provider
        await c.var.db
          .updateTable("ai_key")
          .set({
            encrypted_key: ciphertext,
            key_suffix: keySuffix,
            iv,
            custom_base_url: values.custom_base_url,
            fast_model: values.fast_model,
            thinking_model: values.thinking_model,
          })
          .where("id", "=", existing.id)
          .execute();
      } else {
        await c.var.db
          .insertInto("ai_key")
          .values(values)
          .execute();
      }
    } else {
      // Standard providers: upsert by user_id + provider
      await c.var.db
        .insertInto("ai_key")
        .values(values)
        .onConflict((oc) =>
          oc
            .columns(["user_id", "provider"])
            .where("user_id", "is not", null)
            .where("provider", "!=", "custom" as any)
            .doUpdateSet({
              encrypted_key: ciphertext,
              key_suffix: keySuffix,
              iv,
            })
        )
        .execute();
    }

    return c.json({
      provider,
      key_suffix: keySuffix,
      ...(provider === "custom" ? { name: values.name } : {}),
      ...(validation.error ? { warning: validation.error } : {}),
    });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI key");
  }
});

// DELETE /ai-keys/:id — remove user's key by id
aiKeys.delete("/ai-keys/:id", async (c) => {
  const user = c.var.user;
  const id = c.req.param("id");

  // Also clear any ai_preference references to this key
  await c.var.db
    .updateTable("ai_preference")
    .set((eb: any) => ({
      builtin_ai_key_id: eb.case()
        .when("builtin_ai_key_id", "=", Number(id))
        .then(null)
        .else(eb.ref("builtin_ai_key_id"))
        .end(),
      twist_ai_key_id: eb.case()
        .when("twist_ai_key_id", "=", Number(id))
        .then(null)
        .else(eb.ref("twist_ai_key_id"))
        .end(),
    }))
    .where("user_id", "=", user.id)
    .execute();

  await c.var.db
    .deleteFrom("ai_key")
    .where("user_id", "=", user.id)
    .where("id", "=", Number(id) as any)
    .execute();

  return c.json({ success: true });
});

// GET /ai-preference — get user's AI provider selections
aiKeys.get("/ai-preference", async (c) => {
  const user = c.var.user;

  const pref = await c.var.db
    .selectFrom("ai_preference")
    .select(["builtin_ai_key_id", "twist_ai_key_id", "twist_ai_disabled", "builtin_ai_disabled"])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  return c.json(pref ?? { builtin_ai_key_id: null, twist_ai_key_id: null, twist_ai_disabled: false, builtin_ai_disabled: false });
});

// POST /ai-preference — set user's AI provider selections
aiKeys.post("/ai-preference", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{
    builtinAiKeyId?: number | null;
    twistAiKeyId?: number | null;
    twistAiDisabled?: boolean;
    builtinAiDisabled?: boolean;
  }>();

  // Verify any referenced ai_key belongs to the caller. Without this a user
  // could point their preference at any other user's key id and route AI
  // calls through (and bill) the victim's key.
  for (const keyId of [body.builtinAiKeyId, body.twistAiKeyId]) {
    if (keyId == null) continue;
    const row = await c.var.db
      .selectFrom("ai_key")
      .select(["user_id"])
      .where("id", "=", Number(keyId) as any)
      .executeTakeFirst();
    if (!row || row.user_id !== user.id) {
      return c.json({ error: "ai_key not found" }, 404);
    }
  }

  try {
    const values: any = {
      user_id: user.id,
    };
    if (body.builtinAiKeyId !== undefined) values.builtin_ai_key_id = body.builtinAiKeyId;
    if (body.twistAiKeyId !== undefined) values.twist_ai_key_id = body.twistAiKeyId;
    if (body.twistAiDisabled !== undefined) values.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) values.builtin_ai_disabled = body.builtinAiDisabled;

    const updateSet: any = {};
    if (body.builtinAiKeyId !== undefined) updateSet.builtin_ai_key_id = body.builtinAiKeyId;
    if (body.twistAiKeyId !== undefined) updateSet.twist_ai_key_id = body.twistAiKeyId;
    if (body.twistAiDisabled !== undefined) updateSet.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) updateSet.builtin_ai_disabled = body.builtinAiDisabled;

    await c.var.db
      .insertInto("ai_preference")
      .values(values)
      .onConflict((oc) =>
        oc
          .column("user_id")
          .where("user_id", "is not", null)
          .doUpdateSet(updateSet)
      )
      .execute();

    // Backward compat: derive user_settings.ai_enabled from both disabled flags
    const builtinDisabled = body.builtinAiDisabled ?? false;
    const twistDisabled = body.twistAiDisabled ?? false;
    if (body.builtinAiDisabled !== undefined || body.twistAiDisabled !== undefined) {
      // Re-read the full preference to get both flags accurately
      const fullPref = await c.var.db
        .selectFrom("ai_preference")
        .select(["builtin_ai_disabled", "twist_ai_disabled"])
        .where("user_id", "=", user.id)
        .executeTakeFirst();
      const allDisabled = (fullPref?.builtin_ai_disabled ?? builtinDisabled)
        && (fullPref?.twist_ai_disabled ?? twistDisabled);
      await c.var.db
        .insertInto("user_settings")
        .values({ user_id: user.id, ai_enabled: !allDisabled } as any)
        .onConflict((oc) =>
          oc.column("user_id").doUpdateSet({ ai_enabled: !allDisabled } as any)
        )
        .execute();
    }

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI preference");
  }
});

// ---------------------------------------------------------------------------
// Org admin endpoints
// ---------------------------------------------------------------------------

async function requireOrgAdmin(c: any, orgId: string) {
  const user = c.var.user;
  const member = await c.var.db
    .selectFrom("team_user")
    .select(["id", "role"])
    .where("team_id", "=", orgId as any)
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!member || member.role !== "admin") {
    return null;
  }
  return member;
}

// GET /team/:id/ai-keys — list org's key metadata
aiKeys.get("/team/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const keys = await c.var.db
    .selectFrom("ai_key")
    .select(["id", "provider", "name", "key_suffix", "custom_base_url", "fast_model", "thinking_model", "created_at"])
    .where("team_id", "=", orgId as any)
    .execute();

  return c.json(keys);
});

// POST /team/:id/ai-keys — add or replace an org key
aiKeys.post("/team/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<AiKeyBody>();

  const error = validateBody(body);
  if (error) return c.json({ error }, 400);

  const key = body.key.trim();
  const provider = body.provider as AiProvider;

  const validation = await validateAiKey(
    provider,
    key,
    provider === "custom" ? body.customBaseUrl!.trim() : undefined
  );
  if (!validation.valid) {
    return c.json({ error: validation.error ?? "Invalid API key" }, 400);
  }

  try {
    const { ciphertext, iv } = await encrypt(key, c.env.AI_KEY_ENCRYPTION_KEY);
    const keySuffix = key.slice(-4);

    const values: any = {
      team_id: orgId as any,
      provider: provider as any,
      encrypted_key: ciphertext,
      key_suffix: keySuffix,
      iv,
    };

    if (provider === "custom") {
      values.name = body.name!.trim();
      values.custom_base_url = body.customBaseUrl!.trim().replace(/\/+$/, "");
      values.fast_model = body.fastModel!.trim();
      values.thinking_model = body.thinkingModel!.trim();
    }

    if (provider === "custom") {
      const existing = await c.var.db
        .selectFrom("ai_key")
        .select("id")
        .where("team_id", "=", orgId as any)
        .where("provider", "=", "custom" as any)
        .where("name", "=", values.name)
        .executeTakeFirst();

      if (existing) {
        await c.var.db
          .updateTable("ai_key")
          .set({
            encrypted_key: ciphertext,
            key_suffix: keySuffix,
            iv,
            custom_base_url: values.custom_base_url,
            fast_model: values.fast_model,
            thinking_model: values.thinking_model,
          })
          .where("id", "=", existing.id)
          .execute();
      } else {
        await c.var.db
          .insertInto("ai_key")
          .values(values)
          .execute();
      }
    } else {
      await c.var.db
        .insertInto("ai_key")
        .values(values)
        .onConflict((oc) =>
          oc
            .columns(["team_id", "provider"])
            .where("team_id", "is not", null)
            .where("provider", "!=", "custom" as any)
            .doUpdateSet({
              encrypted_key: ciphertext,
              key_suffix: keySuffix,
              iv,
            })
        )
        .execute();
    }

    return c.json({
      provider,
      key_suffix: keySuffix,
      ...(provider === "custom" ? { name: values.name } : {}),
      ...(validation.error ? { warning: validation.error } : {}),
    });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI key");
  }
});

// DELETE /team/:id/ai-keys/:keyId — remove org key by id
aiKeys.delete("/team/:id/ai-keys/:keyId", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const keyId = c.req.param("keyId");

  // Also clear any ai_preference references to this key
  await c.var.db
    .updateTable("ai_preference")
    .set((eb: any) => ({
      builtin_ai_key_id: eb.case()
        .when("builtin_ai_key_id", "=", Number(keyId))
        .then(null)
        .else(eb.ref("builtin_ai_key_id"))
        .end(),
      twist_ai_key_id: eb.case()
        .when("twist_ai_key_id", "=", Number(keyId))
        .then(null)
        .else(eb.ref("twist_ai_key_id"))
        .end(),
    }))
    .where("team_id", "=", orgId as any)
    .execute();

  await c.var.db
    .deleteFrom("ai_key")
    .where("team_id", "=", orgId as any)
    .where("id", "=", Number(keyId) as any)
    .execute();

  return c.json({ success: true });
});

// GET /team/:id/ai-preference
aiKeys.get("/team/:id/ai-preference", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const pref = await c.var.db
    .selectFrom("ai_preference")
    .select(["builtin_ai_key_id", "twist_ai_key_id", "twist_ai_disabled", "builtin_ai_disabled"])
    .where("team_id", "=", orgId as any)
    .executeTakeFirst();

  return c.json(pref ?? { builtin_ai_key_id: null, twist_ai_key_id: null, twist_ai_disabled: false, builtin_ai_disabled: false });
});

// POST /team/:id/ai-preference
aiKeys.post("/team/:id/ai-preference", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{
    builtinAiKeyId?: number | null;
    twistAiKeyId?: number | null;
    twistAiDisabled?: boolean;
    builtinAiDisabled?: boolean;
  }>();

  // Verify any referenced ai_key belongs to this team. Without this an admin
  // of team A could route team-A AI calls through team B's key id.
  for (const keyId of [body.builtinAiKeyId, body.twistAiKeyId]) {
    if (keyId == null) continue;
    const row = await c.var.db
      .selectFrom("ai_key")
      .select(["team_id"])
      .where("id", "=", Number(keyId) as any)
      .executeTakeFirst();
    if (!row || row.team_id == null || String(row.team_id) !== orgId) {
      return c.json({ error: "ai_key not found" }, 404);
    }
  }

  try {
    const values: any = {
      team_id: orgId as any,
    };
    if (body.builtinAiKeyId !== undefined) values.builtin_ai_key_id = body.builtinAiKeyId;
    if (body.twistAiKeyId !== undefined) values.twist_ai_key_id = body.twistAiKeyId;
    if (body.twistAiDisabled !== undefined) values.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) values.builtin_ai_disabled = body.builtinAiDisabled;

    const updateSet: any = {};
    if (body.builtinAiKeyId !== undefined) updateSet.builtin_ai_key_id = body.builtinAiKeyId;
    if (body.twistAiKeyId !== undefined) updateSet.twist_ai_key_id = body.twistAiKeyId;
    if (body.twistAiDisabled !== undefined) updateSet.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) updateSet.builtin_ai_disabled = body.builtinAiDisabled;

    await c.var.db
      .insertInto("ai_preference")
      .values(values)
      .onConflict((oc) =>
        oc
          .column("team_id")
          .where("team_id", "is not", null)
          .doUpdateSet(updateSet)
      )
      .execute();

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to save AI preference");
  }
});

export default aiKeys;
