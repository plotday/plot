/**
 * Immediate, gate-bypassing push for freshly-ingested CTA notes.
 *
 * OTP codes and confirm links are time-sensitive: we want the app to wake and
 * display them even when the user is active or in a notify-window quiet period.
 * This module deliberately does NOT route through push-notify.ts's importance /
 * inactivity / notify-window gates — it sends a data-only (silent) push
 * directly so the client syncs and reads the cta from the local DB. The actual
 * code or URL is never transmitted through FCM/APNs.
 *
 * A 5-minute staleness guard prevents double-firing on re-syncs: if the note's
 * source_created_at is older than 5 minutes at persist time, we skip the push.
 */

import type { Kysely } from "kysely";
import type { DB } from "../db";
import type { Bindings } from "../env";
import { sendDataNotificationToUser } from "./send";

const WINDOW_MS = 5 * 60 * 1000;

/**
 * Fire an immediate, gate-bypassing OTP/confirm push for a freshly-ingested
 * note that carries a `cta`. Data-only: the code is read from the local DB on
 * the client, never sent through FCM/APNs. No-op when the note is older than
 * the 5-minute window at persist time. Deliberately does NOT route through
 * push-notify.ts's importance/inactivity/notify-window gates.
 */
export async function maybeSendCtaPush(
  env: Bindings,
  db: Kysely<DB>,
  note: {
    id: string;
    threadId: string;
    sourceCreatedAt: Date;
    cta: { kind: string } | null;
  }
): Promise<void> {
  if (!note.cta) return;
  if (Date.now() - note.sourceCreatedAt.getTime() > WINDOW_MS) return;

  const rows = await db
    .selectFrom("thread_priority")
    .select("user_id")
    .where("thread_id", "=", note.threadId)
    .where("revoked_at", "is", null)
    // Respect mute: a thread the user muted directly, or one matched to a
    // mute rule, should never wake the client — even for a time-sensitive
    // cta. (Login codes rarely match a mute rule's title/embedding anyway.)
    .where("mute_by_thread_id", "is", null)
    .execute();

  const seen = new Set<string>();
  for (const { user_id } of rows) {
    if (seen.has(user_id)) continue;
    seen.add(user_id);
    await sendDataNotificationToUser(env, db, user_id, {
      type: "otp",
      noteId: note.id,
      threadId: note.threadId,
      kind: note.cta.kind,
    });
  }
}
