import { Hono } from "hono";

import { createFrontendDb, mapPgError } from "../../db";
import type { Bindings } from "../../env";
import { createLogger } from "@plotday/worker-util";
import { notifySync, getPriorityForThread } from "./notify";
import {
  resolveCreateLinkContacts,
  dispatchCreateLink,
  noteActionsToAttachments,
  type PendingCreateLink,
} from "./create-link-dispatch";

const noteRetrySend = new Hono<{ Bindings: Bindings }>();

// POST /sync/note-retry-send — retry a previously failed outbound send.
//
// Body: { note_id }
//
// A note whose `delivery_error` is set failed to send/write-back to its
// connector. Retry clears `delivery_error` (optimistic; bumps note.seq so the
// cleared state syncs) and re-dispatches the connector callback:
//
//   - Reply / write-back (the thread has a connector link): notify the
//     connector's TwistSync DO so the existing updates pipeline re-queries the
//     channel-note-create view and re-runs onNoteCreated.
//   - Compose (the failed note opened a thread via onCreateLink, which leaves
//     no link but stashes `thread.pending_create_link`): rebuild the draft from
//     the thread + stashed spec and re-dispatch create_link.
//
// The connector's own idempotency guard prevents a double-send if the original
// actually went out; otherwise it re-attempts and, on a fresh failure, re-marks
// delivery_error via the runtime. Returns `{ redispatched }`.
noteRetrySend.post("/sync/note-retry-send", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const noteId = body.note_id as string | undefined;
  if (!noteId) {
    return c.json({ ok: false, error: "note_id required" }, 400);
  }

  // Only the note's author may retry it, and only when it actually failed.
  const note = await c.var.db
    .selectFrom("note")
    .select(["id", "thread_id", "content", "actions"])
    .where("id", "=", noteId)
    .where("created_by", "=", userId)
    .where("delivery_error", "is not", null)
    .executeTakeFirst();
  if (!note?.thread_id) {
    return c.json({ ok: false, error: "not found" }, 404);
  }
  const threadId = note.thread_id;

  const thread = await c.var.db
    .selectFrom("thread")
    .select(["title", "contacts", "groups", "pending_create_link"])
    .where("id", "=", threadId)
    .executeTakeFirst();

  // Connectors with a link on this thread are the ones whose onNoteCreated the
  // reply was dispatched to (the reply / write-back case).
  const connectors = await c.var.db
    .selectFrom("link as l")
    .innerJoin("twist_instance as ti", "ti.id", "l.created_by")
    .select("ti.id as twist_instance_id")
    .distinct()
    .where("l.thread_id", "=", threadId)
    .where("ti.archived_at", "is", null)
    .execute();

  const composeSpec = parsePendingCreateLink(thread?.pending_create_link);
  const mode: "reply" | "compose" | "none" =
    connectors.length > 0 ? "reply" : composeSpec ? "compose" : "none";

  if (mode === "none") {
    // Nothing to re-dispatch to (e.g. a compose whose spec was already
    // cleared). Leave the marker; the caller can fall back to re-composing.
    return c.json({ ok: true, redispatched: false });
  }

  // Optimistically clear the failure. The UPDATE bumps note.seq, syncing the
  // cleared state and (for replies) re-qualifying the note for dispatch.
  try {
    await c.var.db
      .updateTable("note")
      .set({ delivery_error: null })
      .where("id", "=", noteId)
      .where("created_by", "=", userId)
      .execute();
  } catch (err) {
    if (!mapPgError(err)) throw err;
    return c.json({ ok: false, error: "clear failed" }, 500);
  }

  if (mode === "reply") {
    for (const { twist_instance_id } of connectors) {
      try {
        const id = c.env.TWIST_SYNC.idFromName(twist_instance_id);
        const stub = c.env.TWIST_SYNC.get(id);
        c.executionCtx.waitUntil(
          stub.fetch(
            new Request("http://do/notify", {
              method: "POST",
              body: JSON.stringify({ id: twist_instance_id }),
            }),
          ),
        );
      } catch (err) {
        createLogger({ operation: "note-retry-send" }).error(
          "Failed to notify connector TwistSync for retry",
          err as Error,
          { twist_instance_id, note_id: noteId },
        );
      }
    }
    try {
      const priorityId = await getPriorityForThread(c.var.db, threadId, userId);
      notifySync(c, priorityId);
    } catch {
      // Thread may not be filed under a priority for this user; skip.
    }
    return c.json({ ok: true, redispatched: true });
  }

  // Compose: rebuild the draft and re-dispatch create_link. Fire-and-forget in
  // waitUntil with a fresh DB connection (the request-scoped one is torn down
  // when the response returns).
  const spec = composeSpec!;
  const title = thread?.title ?? "";
  const noteContent = note.content ?? null;
  const contactIds = (thread?.contacts ?? []) as string[];
  const groupIds = (thread?.groups ?? []) as string[];
  // Unlike the initial compose dispatch (sync/threads), which reads file
  // actions from the client-sent `note_actions` control field because the
  // note isn't reliably persisted yet, by retry time the note IS in the DB —
  // so read its file actions straight from the persisted `note.actions`.
  const noteAttachments = noteActionsToAttachments(note.actions);
  const tracker = c.var.tracker;

  c.executionCtx.waitUntil(
    (async () => {
      const db = createFrontendDb(c.env);
      try {
        const contacts = await resolveCreateLinkContacts(
          db,
          userId,
          contactIds,
          groupIds,
          (error: unknown) => {
            console.error("[note-retry-send] expand_group_contacts failed:", error);
            tracker.captureException(error as Error);
          },
        );
        await dispatchCreateLink(c.env, c.executionCtx as any, db, {
          threadId,
          twistInstanceId: spec.twist_instance_id,
          draft: {
            channelId: spec.channel_id ?? "",
            type: spec.type,
            status: spec.status ?? "",
            title,
            noteContent,
            contacts,
            inviteEmails: spec.invite_emails ?? [],
            attachments: noteAttachments,
          },
        });
      } catch (error) {
        console.error("[note-retry-send] create_link re-dispatch failed:", error);
        tracker.captureException(error as Error);
      } finally {
        await db.destroy();
      }
    })(),
  );

  return c.json({ ok: true, redispatched: true });
});

function parsePendingCreateLink(value: unknown): PendingCreateLink | null {
  if (value == null) return null;
  const parsed: unknown =
    typeof value === "string" ? safeJsonParse(value) : value;
  if (!parsed || typeof parsed !== "object") return null;
  const p = parsed as Record<string, unknown>;
  if (typeof p.twist_instance_id !== "string" || typeof p.type !== "string") {
    return null;
  }
  return {
    twist_instance_id: p.twist_instance_id,
    channel_id: typeof p.channel_id === "string" ? p.channel_id : null,
    type: p.type,
    status: typeof p.status === "string" ? p.status : null,
    invite_emails: Array.isArray(p.invite_emails)
      ? p.invite_emails.filter((e): e is string => typeof e === "string")
      : [],
  };
}

function safeJsonParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

export default noteRetrySend;
