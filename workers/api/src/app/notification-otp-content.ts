import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";

const notificationOtpContent = new Hono<{ Bindings: Bindings }>();

/**
 * GET /notification-otp-content?noteId=<uuid>
 *
 * Returns the CTA payload for a single note. Called by the background FCM
 * isolate when it receives a `type:"otp"` push so it can build a rich OS
 * notification without transmitting sensitive fields through FCM.
 *
 * Access control: the authenticated user must own a thread_priority row for
 * the thread that contains the note. On any miss (no access / not found / no
 * cta) it returns 200 with `{cta:null, threadId:null}` rather than 403/404, so
 * callers can't enumerate note IDs.
 *
 * Response on success:
 *   { cta: { kind: "otp"|"confirm", service: string, code?: string, url?: string },
 *     threadId: string }
 *
 * Response when note not found / user has no access / note has no cta:
 *   { cta: null, threadId: null }
 */
notificationOtpContent.get("/notification-otp-content", async (c) => {
  try {
    const noteId = c.req.query("noteId");
    if (!noteId) {
      return c.json({ cta: null, threadId: null });
    }

    const db = c.var.db;
    const userId = c.var.user.id;

    const rows = await sql<{
      cta: string | null;
      thread_id: string;
    }>`
      SELECT n.cta, n.thread_id::text
      FROM note n
      JOIN thread_priority tp ON tp.thread_id = n.thread_id
        AND tp.user_id = ${userId}::uuid
        AND tp.revoked_at IS NULL
      WHERE n.id = ${noteId}::uuid
        AND n.archived_at IS NULL
      LIMIT 1
    `.execute(db);

    if (rows.rows.length === 0 || !rows.rows[0].cta) {
      return c.json({ cta: null, threadId: null });
    }

    const row = rows.rows[0];
    let cta: unknown;
    try {
      cta = typeof row.cta === "string" ? JSON.parse(row.cta) : row.cta;
    } catch {
      return c.json({ cta: null, threadId: null });
    }

    return c.json({ cta, threadId: row.thread_id });
  } catch (error) {
    return captureServerError(c, error, "Error fetching OTP notification content.");
  }
});

export default notificationOtpContent;
