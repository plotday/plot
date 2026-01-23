import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";
import { sendInvitation } from "./invitation";

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
  }

  // Combine UUIDs with contact IDs from emails
  const allAddIds = [...addUuids, ...contactIdsFromEmails];

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

  // Send invitation emails to non-user contacts (fire-and-forget with waitUntil)
  if (nonUserContactIds.length > 0) {
    // Use waitUntil to ensure emails complete even after response is sent
    c.executionCtx.waitUntil(
      Promise.allSettled(
        nonUserContactIds.map((contactId) =>
          sendInvitation(c.var.supabaseAdmin, {
            contactId,
            priorityId,
            inviterUserId: user.id,
            resendApiKey: c.env.RESEND_API_KEY,
          })
        )
      )
        .then((results) => {
          // Log all results
          results.forEach((result, index) => {
            const contactId = nonUserContactIds[index];
            if (result.status === "rejected") {
              console.error(
                `[Contact ${contactId}] Email send rejected:`,
                result.reason
              );
            }
          });
        })
        .catch((error) => {
          console.error("Unexpected error sending invitation emails:", error);
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

  // Fetch users with access (via priority_contact)
  const { data: users, error: usersError } = await c.var.supabaseAdmin
    .from("priority_contact")
    .select(
      `
      contact:contact!inner(id, email, name, user_id)
    `
    )
    .eq("priority_id", priorityId)
    .is("archived_at", null);

  if (usersError) {
    return captureServerError(
      c,
      new Error(usersError.message),
      "Failed to fetch priority users",
      {
        priority_id: priorityId,
      }
    );
  }

  // Fetch pending invitations
  const { data: invitations, error: invitationsError } =
    await c.var.supabaseAdmin
      .from("priority_invitation")
      .select(
        `
      id,
      contact:contact!inner(id, email, name)
    `
      )
      .eq("priority_id", priorityId)
      .is("archived_at", null);

  if (invitationsError) {
    return captureServerError(
      c,
      new Error(invitationsError.message),
      "Failed to fetch invitations",
      {
        priority_id: priorityId,
      }
    );
  }

  return c.json({
    id: priority.id,
    title: priority.title,
    path: priority.path,
    extracted: shareResult?.extracted ?? false,
    oldPath: shareResult?.oldPath ?? null,
    users: (users ?? []).map((u: any) => ({
      id: u.contact?.user_id,
      contactId: u.contact?.id,
      email: u.contact?.email,
      name: u.contact?.name,
    })),
    invitations: (invitations ?? []).map((i: any) => ({
      id: i.id,
      contactId: i.contact?.id,
      email: i.contact?.email,
      name: i.contact?.name,
    })),
  });
});

export default share;
