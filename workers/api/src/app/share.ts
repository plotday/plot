import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";
import { sendInvitation } from "./invitation";
import { createLogger } from "@plotday/worker-util";

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
  logger.info("Request to share priority", { priority_id: priorityId, user_id: user?.id });

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

  logger.info("Parsed share request", { add, remove });

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

  logger.info("Partitioned identifiers", { uuid_count: addUuids.length, email_count: addEmails.length });

  // If there are emails, upsert contacts first
  let contactIdsFromEmails: string[] = [];
  let nonUserContactIds: string[] = [];
  if (addEmails.length > 0) {
    const contactsToUpsert = addEmails.map((email) => ({ email }));

    const { data: upsertedContacts, error: upsertError } =
      await c.var.supabaseAdmin.rpc("upsert_contacts", {
        contacts: contactsToUpsert,
      });

    if (upsertError) {
      return captureServerError(
        c,
        new Error(upsertError.message),
        "Failed to create contacts",
        {
          priority_id: priorityId,
          user_id: user.id,
          emails: addEmails,
        }
      );
    }

    // Extract contact IDs from the upserted results
    const contacts = upsertedContacts as Array<{
      id: string;
      user_id: string | null;
    }>;
    contactIdsFromEmails = contacts.map((c) => c.id);

    // Track non-user contacts (user_id is null)
    nonUserContactIds = contacts
      .filter((c) => c.user_id === null)
      .map((c) => c.id);

    const logger = createLogger({ component: "share" });
    logger.info("Upserted contacts for sharing", {
      total_contacts: contacts.length,
      non_user_contacts: nonUserContactIds.length
    });
  }

  // Combine UUIDs with contact IDs from emails
  const allAddIds = [...addUuids, ...contactIdsFromEmails];

  logger.info("Calling share_priority", {
    add_count: allAddIds.length,
    remove_count: remove.length
  });

  // Call the share_priority function
  // Using supabaseAdmin since the function is revoked from authenticated
  const { data, error: shareError } = await c.var.supabaseAdmin.rpc(
    "share_priority",
    {
      p_user_id: user.id,
      p_priority_id: priorityId,
      p_add_actor_ids: allAddIds,
      p_remove_actor_ids: remove,
    }
  );
  const shareResult = data as SharePriorityResult | null;

  if (shareError) {
    logger.error("share_priority failed", new Error(shareError.message));
  } else {
    logger.info("share_priority completed", { added_contacts: allAddIds.length });
  }

  if (shareError) {
    // Check for access denied error
    if (shareError.message.includes("does not have access")) {
      return c.json({ message: "Access denied" }, 403);
    }
    if (shareError.message.includes("not found")) {
      return c.json({ message: "Priority not found" }, 404);
    }
    return captureServerError(
      c,
      new Error(shareError.message),
      "Failed to share priority",
      {
        priority_id: priorityId,
        user_id: user.id,
      }
    );
  }

  // Check which of the newly added contacts need invitation emails
  // This handles both contacts from emails AND contacts passed as UUIDs
  let finalNonUserContactIds: string[] = [];
  if (allAddIds.length > 0) {
    const { data: addedContacts, error: contactCheckError } = await c.var.supabaseAdmin
      .from("contact")
      .select("id, user_id")
      .in("id", allAddIds);

    if (contactCheckError) {
      logger.error("Failed to check added contacts", new Error(contactCheckError.message));
    } else if (addedContacts) {
      finalNonUserContactIds = addedContacts
        .filter((c) => c.user_id === null)
        .map((c) => c.id);

      logger.info("Checked added contacts for invitations", {
        total_added: allAddIds.length,
        non_user_contacts: finalNonUserContactIds.length
      });
    }
  }

  // Send invitation emails to non-user contacts (fire-and-forget with waitUntil)
  if (finalNonUserContactIds.length > 0) {
    const logger = createLogger({ component: "share" });
    logger.info("Queuing invitation emails", {
      count: finalNonUserContactIds.length,
      priority_id: priorityId
    });
    // Use waitUntil to ensure emails complete even after response is sent
    c.executionCtx.waitUntil(
      Promise.allSettled(
        finalNonUserContactIds.map((contactId) =>
          sendInvitation(c.var.supabaseAdmin, {
            contactId,
            priorityId,
            inviterUserId: user.id,
            mailQueue: c.env.MAIL_QUEUE,
            siteRoot: c.env.SITE_ROOT,
          })
        )
      )
        .then((results) => {
          const logger = createLogger({ component: "share" });
          logger.info("Invitation sending complete", { results_count: results.length });
          // Log all results and capture failures in PostHog
          results.forEach((result, index) => {
            const contactId = finalNonUserContactIds[index];
            if (result.status === "rejected") {
              const error = result.reason instanceof Error
                ? result.reason
                : new Error(String(result.reason));
              logger.error("Email send rejected", error, { contact_id: contactId });
              c.var.postHog.captureException(error, undefined, {
                contact_id: contactId,
                priority_id: priorityId,
                inviter_user_id: user.id,
                error_context: "invitation_email_queue_failed",
              });
            } else if (result.status === "fulfilled" && !result.value.success) {
              // sendInvitation returned success: false
              const error = new Error(result.value.error || "Unknown error");
              logger.error("Email send failed", error, {
                contact_id: contactId,
                error_message: result.value.error
              });
              c.var.postHog.captureException(error, undefined, {
                contact_id: contactId,
                priority_id: priorityId,
                inviter_user_id: user.id,
                error_context: "invitation_email_send_failed",
                skipped: result.value.skipped,
              });
            }
          });
        })
        .catch((error) => {
          const logger = createLogger({ component: "share" });
          const err = error instanceof Error ? error : new Error(String(error));
          logger.error("Unexpected error sending invitation emails", err);
          c.var.postHog.captureException(err, undefined, {
            priority_id: priorityId,
            inviter_user_id: user.id,
            error_context: "invitation_email_unexpected_error",
          });
        })
    );
  }

  // Fetch updated priority info
  const { data: priority, error: priorityError } = await c.var.supabaseAdmin
    .from("priority")
    .select("id, title, path")
    .eq("id", priorityId)
    .single();

  if (priorityError || !priority) {
    return captureServerError(
      c,
      priorityError
        ? new Error(priorityError.message)
        : new Error("Priority not found"),
      "Failed to fetch updated priority",
      { priority_id: priorityId }
    );
  }

  // Fetch all contacts with access (via priority_contact)
  // This includes both users (contact.user_id is set) and invitations (contact.user_id is null)
  const { data: contacts, error: contactsError } = await c.var.supabaseAdmin
    .from("priority_contact")
    .select(
      `
      id,
      contact:contact!inner(id, email, name, user_id)
    `
    )
    .eq("priority_id", priorityId)
    .or("invited_by.is.null,invited_at.not.is.null");

  if (contactsError) {
    return captureServerError(
      c,
      new Error(contactsError.message),
      "Failed to fetch priority contacts",
      {
        priority_id: priorityId,
      }
    );
  }

  // Separate contacts into users (has user_id) and invitations (no user_id)
  const allContacts = contacts ?? [];
  const users = allContacts.filter((c: any) => c.contact?.user_id != null);
  const invitations = allContacts.filter((c: any) => c.contact?.user_id == null);

  return c.json({
    id: priority.id,
    title: priority.title,
    path: priority.path,
    extracted: shareResult?.extracted ?? false,
    oldPath: shareResult?.oldPath ?? null,
    users: users.map((u: any) => ({
      id: u.contact?.user_id,
      contactId: u.contact?.id,
      email: u.contact?.email,
      name: u.contact?.name,
    })),
    invitations: invitations.map((i: any) => ({
      id: i.id,
      contactId: i.contact?.id,
      email: i.contact?.email,
      name: i.contact?.name,
    })),
  });
});

export default share;
