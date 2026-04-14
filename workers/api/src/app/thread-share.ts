import { Hono } from "hono";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";
import { sendInvitation } from "./invitation";

const threadShare = new Hono<{ Bindings: Bindings }>();

const uuidRegex =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const ShareRequestSchema = z.object({
  add: z.array(z.string()).default([]),
  remove: z.array(z.string().uuid()).default([]),
  addTopics: z.array(z.string().uuid()).default([]),
  removeTopics: z.array(z.string().uuid()).default([]),
});

// POST /thread/:id/share - Share a thread with other users/contacts
threadShare.post("/thread/:id/share", async (c) => {
  const threadId = c.req.param("id");
  const user = c.var.user;

  const logger = createLogger({ component: "thread-share" });

  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const uuidSchema = z.string().uuid();
  const threadIdResult = uuidSchema.safeParse(threadId);
  if (!threadIdResult.success) {
    return c.json({ message: "Invalid thread ID" }, 400);
  }

  const rawBody = await c.req.json();
  const parseResult = ShareRequestSchema.safeParse(rawBody);

  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { add, remove, addTopics, removeTopics } = parseResult.data;

  if (add.length === 0 && remove.length === 0 && addTopics.length === 0 && removeTopics.length === 0) {
    return c.json({ message: "No changes to make" }, 400);
  }

  if (add.length > 0 || remove.length > 0) {
    // Partition add array into UUIDs and emails
    const addUuids: string[] = [];
    const addEmails: string[] = [];

    for (const item of add) {
      if (uuidRegex.test(item)) {
        addUuids.push(item);
      } else if (emailRegex.test(item)) {
        addEmails.push(item.toLowerCase());
      } else {
        return c.json(
          { message: `Invalid identifier: ${item}. Must be a UUID or email address.` },
          400
        );
      }
    }

    // Upsert contacts from emails
    let contactIdsFromEmails: string[] = [];
    if (addEmails.length > 0) {
      try {
        const contacts = await rpc(c.var.db, "upsert_contacts", {
          contacts: JSON.stringify(addEmails.map((email) => ({ email }))),
        });
        const contactRows = Array.isArray(contacts) ? contacts : [contacts];
        contactIdsFromEmails = contactRows.map((row: { id: string }) => row.id);
      } catch (upsertError) {
        return captureServerError(
          c,
          upsertError as Error,
          "Failed to create contacts",
          { thread_id: threadId, user_id: user.id, emails: addEmails }
        );
      }
    }

    const allAddIds = [...addUuids, ...contactIdsFromEmails];

    // Call share_thread RPC
    let shareResult: { contacts: string[]; needs_invitation: string[] };
    try {
      const data = await c.var.db.transaction().execute(async (trx) => {
        return rpc(trx, "share_thread", {
          p_user_id: user.id,
          p_thread_id: threadId,
          p_add_contact_ids: `{${allAddIds.join(",")}}` as any,
          p_remove_contact_ids: `{${remove.join(",")}}` as any,
        });
      });
      shareResult = data as unknown as typeof shareResult;
      logger.info("share_thread completed", {
        thread_id: threadId,
        added: allAddIds.length,
        removed: remove.length,
      });
    } catch (shareError) {
      const errMsg = (shareError as Error).message;
      if (errMsg.includes("does not have access")) {
        return c.json({ message: "Access denied" }, 403);
      }
      return captureServerError(
        c,
        shareError as Error,
        "Failed to share thread",
        { thread_id: threadId, user_id: user.id }
      );
    }

    // Send invitation emails to non-user contacts
    const needsInvitation = shareResult.needs_invitation ?? [];
    if (needsInvitation.length > 0) {
      const results = await Promise.allSettled(
        needsInvitation.map((contactId) =>
          sendInvitation(c.var.db, {
            contactId,
            threadId,
            inviterUserId: user.id,
            mailQueue: c.env.MAIL_QUEUE,
            appRoot: c.env.APP_ROOT,
          })
        )
      );

      for (let i = 0; i < results.length; i++) {
        const result = results[i];
        const contactId = needsInvitation[i];
        if (result.status === "rejected") {
          const error =
            result.reason instanceof Error
              ? result.reason
              : new Error(String(result.reason));
          logger.error("Email send rejected", error, { contact_id: contactId });
          c.var.tracker.captureException(error, {
            contact_id: contactId,
            thread_id: threadId,
            error_context: "thread_invitation_email_failed",
          });
        } else if (result.status === "fulfilled" && !result.value.success && !result.value.skipped) {
          const error = new Error(result.value.error || "Unknown error");
          logger.error("Email send failed", error, { contact_id: contactId });
          c.var.tracker.captureException(error, {
            contact_id: contactId,
            thread_id: threadId,
            error_context: "thread_invitation_email_failed",
          });
        }
      }
    }
  }

  // Share thread with topics
  if (addTopics.length > 0 || removeTopics.length > 0) {
    try {
      await c.var.db.transaction().execute(async (trx) => {
        return rpc(trx, "share_thread_with_topics", {
          p_user_id: user.id,
          p_thread_id: threadId,
          p_add_topic_ids: `{${addTopics.join(",")}}` as any,
          p_remove_topic_ids: `{${removeTopics.join(",")}}` as any,
        });
      });
    } catch (topicError) {
      const errMsg = (topicError as Error).message;
      if (errMsg.includes("does not have access") || errMsg.includes("does not have permission") || errMsg.includes("Only admins")) {
        return c.json({ message: errMsg }, 403);
      }
      return captureServerError(
        c,
        topicError as Error,
        "Failed to share thread with topics",
        { thread_id: threadId, user_id: user.id }
      );
    }
  }

  return c.json({ success: true });
});

export default threadShare;
