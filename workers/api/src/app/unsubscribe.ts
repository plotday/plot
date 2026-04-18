import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { dbMiddleware } from "../middleware/db";

const unsubscribe = new Hono<{ Bindings: Bindings }>();

const VALID_FREQUENCIES = ["daily", "weekly", "never"] as const;
type Frequency = (typeof VALID_FREQUENCIES)[number];

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Public endpoint used by the marketing site's /unsubscribe page. The token
 * comes from the unsubscribe link in notification digest emails and maps to
 * user_settings.email_token. No session is required — the token is a
 * capability that lets the bearer change their own email_frequency.
 */
unsubscribe.post("/unsubscribe", dbMiddleware, async (c) => {
  let body: { token?: unknown; frequency?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "Invalid JSON" }, 400);
  }

  const token = typeof body.token === "string" ? body.token.trim() : "";
  const frequency = body.frequency as Frequency | undefined;

  if (!token || !UUID_RE.test(token)) {
    return c.json({ error: "Invalid token" }, 400);
  }
  if (!frequency || !VALID_FREQUENCIES.includes(frequency)) {
    return c.json({ error: "Invalid frequency" }, 400);
  }

  const result = await sql<{ user_id: string }>`
    UPDATE user_settings
      SET email_frequency = ${frequency}::email_frequency,
          updated_at = now()
      WHERE email_token = ${token}::uuid
      RETURNING user_id::text AS user_id
  `.execute(c.var.db);

  if (result.rows.length === 0) {
    return c.json({ error: "Token not recognized" }, 404);
  }

  return c.json({ ok: true, frequency });
});

export default unsubscribe;
