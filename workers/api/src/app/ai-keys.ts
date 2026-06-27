import { Hono } from "hono";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";

const aiKeys = new Hono<{ Bindings: Bindings }>();

// ---------------------------------------------------------------------------
// User endpoints
// ---------------------------------------------------------------------------

// GET /ai-keys — BYOK removed in B4; always returns empty list for backwards
// compatibility with older Flutter clients that call this on settings open.
aiKeys.get("/ai-keys", async (c) => {
  return c.json([]);
});

// POST /ai-keys — BYOK removed in B4; creating new keys is no longer supported.
aiKeys.post("/ai-keys", async (_c) => {
  return Response.json({ error: "Bring-your-own-key is no longer supported." }, { status: 410 });
});

// DELETE /ai-keys/:id — BYOK removed in B4; no keys to delete.
aiKeys.delete("/ai-keys/:id", async (_c) => {
  return Response.json({ error: "Bring-your-own-key is no longer supported." }, { status: 410 });
});

// GET /ai-preference — get user's AI preference (disabled toggles only; key-id columns removed in B4)
aiKeys.get("/ai-preference", async (c) => {
  const user = c.var.user;

  const pref = await c.var.db
    .selectFrom("ai_preference")
    .select(["twist_ai_disabled", "builtin_ai_disabled"])
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  // Back-compat: older Flutter clients still read builtin_ai_key_id / twist_ai_key_id;
  // always return null (BYOK removed in B4; columns dropped in Task 6 contract migration).
  return c.json({
    builtin_ai_key_id: null,
    twist_ai_key_id: null,
    twist_ai_disabled: pref?.twist_ai_disabled ?? false,
    builtin_ai_disabled: pref?.builtin_ai_disabled ?? false,
  });
});

// POST /ai-preference — set user's AI disabled toggles (key-id fields ignored since B4)
aiKeys.post("/ai-preference", async (c) => {
  const user = c.var.user;
  // builtinAiKeyId / twistAiKeyId are accepted in the body for back-compat but silently
  // ignored — BYOK (bring-your-own-key) was removed in B4. Only the *_disabled toggles
  // are read and written.
  const body = await c.req.json<{
    twistAiDisabled?: boolean;
    builtinAiDisabled?: boolean;
    // Legacy fields — accepted but ignored (back-compat with older clients)
    builtinAiKeyId?: number | null;
    twistAiKeyId?: number | null;
  }>();

  try {
    const values: any = {
      user_id: user.id,
    };
    if (body.twistAiDisabled !== undefined) values.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) values.builtin_ai_disabled = body.builtinAiDisabled;

    const updateSet: any = {};
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

// GET /team/:id/ai-keys — BYOK removed in B4; always returns empty list.
aiKeys.get("/team/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  return c.json([]);
});

// POST /team/:id/ai-keys — BYOK removed in B4; creating new keys is no longer supported.
aiKeys.post("/team/:id/ai-keys", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  return Response.json({ error: "Bring-your-own-key is no longer supported." }, { status: 410 });
});

// DELETE /team/:id/ai-keys/:keyId — BYOK removed in B4; no keys to delete.
aiKeys.delete("/team/:id/ai-keys/:keyId", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  return Response.json({ error: "Bring-your-own-key is no longer supported." }, { status: 410 });
});

// GET /team/:id/ai-preference
aiKeys.get("/team/:id/ai-preference", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const pref = await c.var.db
    .selectFrom("ai_preference")
    .select(["twist_ai_disabled", "builtin_ai_disabled"])
    .where("team_id", "=", orgId as any)
    .executeTakeFirst();

  // Back-compat: older Flutter clients still read builtin_ai_key_id / twist_ai_key_id;
  // always return null (BYOK removed in B4; columns dropped in Task 6 contract migration).
  return c.json({
    builtin_ai_key_id: null,
    twist_ai_key_id: null,
    twist_ai_disabled: pref?.twist_ai_disabled ?? false,
    builtin_ai_disabled: pref?.builtin_ai_disabled ?? false,
  });
});

// POST /team/:id/ai-preference
aiKeys.post("/team/:id/ai-preference", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireOrgAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  // builtinAiKeyId / twistAiKeyId are accepted in the body for back-compat but silently
  // ignored — BYOK (bring-your-own-key) was removed in B4. Only the *_disabled toggles
  // are read and written.
  const body = await c.req.json<{
    twistAiDisabled?: boolean;
    builtinAiDisabled?: boolean;
    // Legacy fields — accepted but ignored (back-compat with older clients)
    builtinAiKeyId?: number | null;
    twistAiKeyId?: number | null;
  }>();

  try {
    const values: any = {
      team_id: orgId as any,
    };
    if (body.twistAiDisabled !== undefined) values.twist_ai_disabled = body.twistAiDisabled;
    if (body.builtinAiDisabled !== undefined) values.builtin_ai_disabled = body.builtinAiDisabled;

    const updateSet: any = {};
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
