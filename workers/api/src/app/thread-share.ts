import { Hono } from "hono";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";
import { sendInvitation } from "./invitation";
import { updateThreadDroppedContacts } from "../twist/sharing";

const threadShare = new Hono<{ Bindings: Bindings }>();

const uuidRegex =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// An add-target can be:
//   - a plain string (UUID or email) — back-compat, no role
//   - { value, role } — UUID/email plus an optional connector role id
const AddTargetSchema = z.union([
  z.string(),
  z.object({ value: z.string(), role: z.string().optional() }),
]);

const ShareRequestSchema = z.object({
  add: z.array(AddTargetSchema).default([]),
  remove: z.array(z.string().uuid()).default([]),
  // Optional role changes on contacts already on the thread.
  roleChanges: z
    .array(
      z.object({
        contactId: z.string().uuid(),
        role: z.string(),
      }),
    )
    .default([]),
  // Accept new `addGroups`/`removeGroups` (apiVersion >= 3) or old
  // `addTopics`/`removeTopics` (apiVersion < 3) — both map to the same RPC.
  addGroups: z.array(z.string().uuid()).optional(),
  removeGroups: z.array(z.string().uuid()).optional(),
  addTopics: z.array(z.string().uuid()).optional(),
  removeTopics: z.array(z.string().uuid()).optional(),
  // Message-mode drop/undrop: move contacts to/from dropped_contacts without
  // changing thread.contacts (they retain visibility). Used by the Flutter
  // sharing modal when the viewer drops or re-adds a participant on a
  // message-mode thread.
  drop: z.array(z.string().uuid()).optional(),
  undrop: z.array(z.string().uuid()).optional(),
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

  const { add, remove, roleChanges } = parseResult.data;
  const addGroups = parseResult.data.addGroups ?? parseResult.data.addTopics ?? [];
  const removeGroups = parseResult.data.removeGroups ?? parseResult.data.removeTopics ?? [];
  const drop = parseResult.data.drop ?? [];
  const undrop = parseResult.data.undrop ?? [];

  if (
    add.length === 0 &&
    remove.length === 0 &&
    roleChanges.length === 0 &&
    addGroups.length === 0 &&
    removeGroups.length === 0 &&
    drop.length === 0 &&
    undrop.length === 0
  ) {
    return c.json({ message: "No changes to make" }, 400);
  }

  if (add.length > 0 || remove.length > 0 || roleChanges.length > 0) {
    // Partition add array into UUIDs and emails, carrying per-target role.
    const addUuids: Array<{ value: string; role?: string }> = [];
    const addEmails: Array<{ value: string; role?: string }> = [];

    for (const item of add) {
      const value = typeof item === "string" ? item : item.value;
      const role = typeof item === "string" ? undefined : item.role;
      if (uuidRegex.test(value)) {
        addUuids.push({ value, role });
      } else if (emailRegex.test(value)) {
        addEmails.push({ value: value.toLowerCase(), role });
      } else {
        return c.json(
          { message: `Invalid identifier: ${value}. Must be a UUID or email address.` },
          400
        );
      }
    }

    // Upsert contacts from emails — map email back to (resolved id, role).
    const contactsByEmail = new Map<string, string>();
    if (addEmails.length > 0) {
      try {
        const contacts = await rpc(c.var.db, "upsert_contacts", {
          contacts: JSON.stringify(addEmails.map((e) => ({ email: e.value }))),
        });
        const contactRows = Array.isArray(contacts) ? contacts : [contacts];
        // Server preserves input order; map by index.
        addEmails.forEach((entry, i) => {
          const row = contactRows[i] as { id: string } | undefined;
          if (row) contactsByEmail.set(entry.value, row.id);
        });
      } catch (upsertError) {
        return captureServerError(
          c,
          upsertError as Error,
          "Failed to create contacts",
          { thread_id: threadId, user_id: user.id, emails: addEmails.map((e) => e.value) }
        );
      }
    }

    // Build the final (contactId, role) list and the flat id list.
    const addEntries: Array<{ contactId: string; role?: string }> = [];
    for (const entry of addUuids) {
      addEntries.push({ contactId: entry.value, role: entry.role });
    }
    for (const entry of addEmails) {
      const contactId = contactsByEmail.get(entry.value);
      if (contactId) addEntries.push({ contactId, role: entry.role });
    }
    const allAddIds = addEntries.map((e) => e.contactId);
    const contactRoles = addEntries
      .filter((e) => e.role)
      .map((e) => ({ contactId: e.contactId, role: e.role }));

    // Call share_thread RPC
    let shareResult: {
      contacts: string[];
      contact_meta?: Record<string, { role?: string; addedBy?: string }>;
      needs_invitation: string[];
    };
    try {
      const data = await c.var.db.transaction().execute(async (trx) => {
        return rpc(trx, "share_thread", {
          p_user_id: user.id,
          p_thread_id: threadId,
          p_add_contact_ids: `{${allAddIds.join(",")}}` as any,
          p_remove_contact_ids: `{${remove.join(",")}}` as any,
          p_contact_roles: JSON.stringify(contactRoles),
          p_role_changes: JSON.stringify(roleChanges),
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

  // Share thread with groups
  if (addGroups.length > 0 || removeGroups.length > 0) {
    try {
      await c.var.db.transaction().execute(async (trx) => {
        return rpc(trx, "share_thread_with_groups", {
          p_user_id: user.id,
          p_thread_id: threadId,
          p_add_group_ids: `{${addGroups.join(",")}}` as any,
          p_remove_group_ids: `{${removeGroups.join(",")}}` as any,
        });
      });
    } catch (groupError) {
      const errMsg = (groupError as Error).message;
      if (errMsg.includes("does not have access") || errMsg.includes("does not have permission") || errMsg.includes("Only admins")) {
        return c.json({ message: errMsg }, 403);
      }
      return captureServerError(
        c,
        groupError as Error,
        "Failed to share thread with groups",
        { thread_id: threadId, user_id: user.id }
      );
    }
  }

  // Message-mode drop/undrop: moves contacts to/from dropped_contacts without
  // touching thread.contacts. Callers supply contact IDs that must already be
  // in thread.contacts (the invariant is enforced by the DB function).
  if (drop.length > 0 || undrop.length > 0) {
    try {
      await updateThreadDroppedContacts(c.var.db, threadId, drop, undrop);
      logger.info("update_thread_dropped_contacts completed", {
        thread_id: threadId,
        dropped: drop.length,
        undropped: undrop.length,
      });
    } catch (dropError) {
      return captureServerError(
        c,
        dropError as Error,
        "Failed to update thread dropped contacts",
        { thread_id: threadId, user_id: user.id }
      );
    }
  }

  return c.json({ success: true });
});

export default threadShare;
