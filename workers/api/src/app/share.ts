import { Hono } from "hono";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";
import { sendInvitation } from "./invitation";
import { notifySync } from "./sync/notify";

const share = new Hono<{ Bindings: Bindings }>();

// Type for the share_priority function response
interface SharePriorityResult {
  id: string;
  extracted: boolean;
  oldPath: string | null;
  newPath: string;
}

// UUID regex pattern for validation
const uuidRegex =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Email regex pattern for validation
const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Schema for share request - accepts both UUIDs and emails in 'add'
const ShareRequestSchema = z.object({
  add: z.array(z.string()).default([]), // UUIDs or emails
  remove: z.array(z.string().uuid()).default([]), // UUIDs only
});

// POST /priority/:id/share - Share a priority with other users/contacts
share.post("/priority/:id/share", async (c) => {
  const priorityId = c.req.param("id");
  const user = c.var.user;

  const logger = createLogger({ component: "share" });
  logger.info("Request to share priority", {
    priority_id: priorityId,
    user_id: user?.id,
  });

  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  // Validate priority ID is a valid UUID
  const uuidSchema = z.string().uuid();
  const priorityIdResult = uuidSchema.safeParse(priorityId);
  if (!priorityIdResult.success) {
    return c.json({ message: "Invalid priority ID" }, 400);
  }

  // Parse request body
  const rawBody = await c.req.json();
  const parseResult = ShareRequestSchema.safeParse(rawBody);

  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { add, remove } = parseResult.data;

  // Check if there's anything to do
  if (add.length === 0 && remove.length === 0) {
    logger.info("No changes to make, returning 400");
    return c.json({ message: "No changes to make" }, 400);
  }

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
        {
          message: `Invalid identifier: ${item}. Must be a UUID or email address.`,
        },
        400
      );
    }
  }

  // If there are emails, upsert contacts first
  let contactIdsFromEmails: string[] = [];
  if (addEmails.length > 0) {
    const contactsToUpsert = addEmails.map((email) => ({ email }));

    try {
      const upsertedContacts = await rpc(c.var.db, "upsert_contacts", {
        contacts: contactsToUpsert,
      });

      // Extract contact IDs from the upserted results
      const contacts = (Array.isArray(upsertedContacts) ? upsertedContacts : [upsertedContacts]) as Array<{
        id: string;
        user_id: string | null;
      }>;
      contactIdsFromEmails = contacts.map((c) => c.id);
    } catch (upsertError) {
      return captureServerError(
        c,
        upsertError as Error,
        "Failed to create contacts",
        {
          priority_id: priorityId,
          user_id: user.id,
          emails: addEmails,
        }
      );
    }
  }

  // Combine UUIDs with contact IDs from emails
  const allAddIds = [...addUuids, ...contactIdsFromEmails];

  // Call the share_priority function
  let shareResult: SharePriorityResult | null = null;
  try {
    const data = await rpc(c.var.db, "share_priority", {
      p_user_id: user.id,
      p_priority_id: priorityId,
      p_add_actor_ids: `{${allAddIds.join(",")}}` as any,
      p_remove_actor_ids: `{${remove.join(",")}}` as any,
    });
    shareResult = data as SharePriorityResult | null;
    logger.info("share_priority completed", {
      added_contacts: allAddIds.length,
    });
  } catch (shareError) {
    const errMsg = (shareError as Error).message;
    logger.error("share_priority failed", shareError as Error);
    // Check for access denied error
    if (errMsg.includes("does not have access")) {
      return c.json({ message: "Access denied" }, 403);
    }
    if (errMsg.includes("not found")) {
      return c.json({ message: "Priority not found" }, 404);
    }
    return captureServerError(
      c,
      shareError as Error,
      "Failed to share priority",
      {
        priority_id: priorityId,
        user_id: user.id,
      }
    );
  }

  notifySync(c, priorityId);

  // Check which of the newly added contacts need invitation emails
  // This handles both contacts from emails AND contacts passed as UUIDs
  let finalNonUserContactIds: string[] = [];
  if (allAddIds.length > 0) {
    try {
      const addedContacts = await c.var.db
        .selectFrom("contact")
        .select(["id", "user_id"])
        .where("id", "in", allAddIds)
        .execute();

      finalNonUserContactIds = addedContacts
        .filter((c) => c.user_id === null)
        .map((c) => c.id);
    } catch (contactCheckError) {
      logger.error(
        "Failed to check added contacts",
        contactCheckError as Error
      );
    }
  }

  // Send invitation emails to non-user contacts
  if (finalNonUserContactIds.length > 0) {
    const results = await Promise.allSettled(
      finalNonUserContactIds.map((contactId) =>
        sendInvitation(c.var.db, {
          contactId,
          priorityId,
          inviterUserId: user.id,
          mailQueue: c.env.MAIL_QUEUE,
          appRoot: c.env.APP_ROOT,
        })
      )
    );

    for (let i = 0; i < results.length; i++) {
      const result = results[i];
      const contactId = finalNonUserContactIds[i];
      if (result.status === "rejected") {
        const error =
          result.reason instanceof Error
            ? result.reason
            : new Error(String(result.reason));
        logger.error("Email send rejected", error, {
          contact_id: contactId,
        });
        c.var.tracker.captureException(error, {
          contact_id: contactId,
          priority_id: priorityId,
          inviter_user_id: user.id,
          error_context: "invitation_email_queue_failed",
        });
      } else if (result.status === "fulfilled" && !result.value.success) {
        const error = new Error(result.value.error || "Unknown error");
        logger.error("Email send failed", error, {
          contact_id: contactId,
          error_message: result.value.error,
        });
        c.var.tracker.captureException(error, {
          contact_id: contactId,
          priority_id: priorityId,
          inviter_user_id: user.id,
          error_context: "invitation_email_send_failed",
          skipped: result.value.skipped,
        });
      }
    }
  }

  // Fetch updated priority info
  let priority;
  try {
    priority = await c.var.db
      .selectFrom("priority")
      .select(["id", "title", "path"])
      .where("id", "=", priorityId)
      .executeTakeFirstOrThrow();
  } catch (priorityError) {
    return captureServerError(
      c,
      priorityError as Error,
      "Failed to fetch updated priority",
      { priority_id: priorityId }
    );
  }

  // Fetch all contacts with access (via priority_contact)
  // This includes both users (contact.user_id is set) and invitations (contact.user_id is null)
  let allContacts: Array<{ id: string; contact_id: string; email: string; name: string | null; user_id: string | null }>;
  try {
    allContacts = await c.var.db
      .selectFrom("priority_contact")
      .innerJoin("contact", "contact.id", "priority_contact.contact_id")
      .select([
        "priority_contact.id",
        "priority_contact.contact_id",
        "contact.email",
        "contact.name",
        "contact.user_id",
      ])
      .where("priority_contact.priority_id", "=", priorityId)
      .where((eb) =>
        eb.or([
          eb("priority_contact.invited_by", "is", null),
          eb("priority_contact.invited_at", "is not", null),
        ])
      )
      .execute();
  } catch (contactsError) {
    return captureServerError(
      c,
      contactsError as Error,
      "Failed to fetch priority contacts",
      {
        priority_id: priorityId,
      }
    );
  }

  // Separate contacts into users (has user_id) and invitations (no user_id)
  const users = allContacts.filter((c) => c.user_id != null);
  const invitations = allContacts.filter((c) => c.user_id == null);

  return c.json({
    id: priority.id,
    title: priority.title,
    path: priority.path,
    extracted: shareResult?.extracted ?? false,
    oldPath: shareResult?.oldPath ?? null,
    users: users.map((u) => ({
      id: u.user_id,
      contactId: u.contact_id,
      email: u.email,
      name: u.name,
    })),
    invitations: invitations.map((i) => ({
      id: i.id,
      contactId: i.contact_id,
      email: i.email,
      name: i.name,
    })),
  });
});

export default share;
