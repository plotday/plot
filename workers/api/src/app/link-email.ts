import { Hono } from "hono";
import { createClerkClient } from "@clerk/backend";

import { render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { sendEmail } from "../email/send";
import { captureServerError } from "../utils/error-capture";
import { classifyInviteable } from "../state/contact-classifier";
import { extractRequestContext } from "../utils/log-context";

const linkEmail = new Hono<{ Bindings: Bindings }>();

/** Generate a 6-digit numeric OTP code. */
function generateOtp(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

/**
 * Sync a verified email to Clerk so the user can sign in with it.
 * Non-blocking — logs errors but never throws.
 */
export async function syncContactToClerk(
  clerkSecretKey: string,
  clerkId: string,
  email: string,
  logContext?: Record<string, unknown>,
): Promise<void> {
  try {
    const clerk = createClerkClient({ secretKey: clerkSecretKey });
    await clerk.emailAddresses.createEmailAddress({
      userId: clerkId,
      emailAddress: email,
      verified: true,
    });
    const logger = createLogger(logContext);
    logger.info("Synced verified email to Clerk", { clerk_id: clerkId, email });
  } catch (error) {
    // Common case: email already exists on this Clerk user — not an error.
    const logger = createLogger(logContext);
    logger.error("Failed to sync email to Clerk (non-blocking)", error as Error, {
      clerk_id: clerkId,
      email,
    });
  }
}

// GET /link-email — List all emails linked to the current user
linkEmail.get("/link-email", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  try {
    const contacts = await c.var.db
      .selectFrom("contact")
      .select(["id", "email", "primary"])
      .where("user_id", "=", user.id)
      .where("email", "is not", null)
      .orderBy("primary", "desc")
      .orderBy("created_at", "asc")
      .execute();

    return c.json({
      emails: contacts.map((row) => ({
        id: row.id,
        email: row.email,
        primary: row.primary,
      })),
    });
  } catch (error) {
    return captureServerError(c, error, "Failed to list linked emails", {
      user_id: user.id,
    });
  }
});

// POST /link-email/primary — Make an email the primary email
linkEmail.post("/link-email/primary", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const body = await c.req.json<{ contactId?: string }>();
  const contactId = body.contactId;

  if (!contactId) {
    return c.json({ error: "contactId is required" }, 400);
  }

  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    // Verify the contact belongs to the current user
    const contact = await c.var.db
      .selectFrom("contact")
      .select(["id", "email", "primary"])
      .where("id", "=", contactId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!contact) {
      return c.json({ error: "Email not found" }, 404);
    }

    if (contact.primary) {
      return c.json({ success: true }); // Already primary — no-op
    }

    // Swap primary: unset old, set new
    await c.var.db
      .updateTable("contact")
      .set({ primary: false })
      .where("user_id", "=", user.id)
      .where("primary", "=", true)
      .execute();

    await c.var.db
      .updateTable("contact")
      .set({ primary: true })
      .where("id", "=", contactId)
      .execute();

    // Update user.email to match the new primary
    if (contact.email) {
      await c.var.db
        .updateTable("user")
        .set({ email: contact.email })
        .where("id", "=", user.id)
        .execute();
    }

    logger.info("Changed primary email", {
      user_id: user.id,
      contact_id: contactId,
      email: contact.email,
    });

    // Sync to Clerk: make this email primary there too
    try {
      const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
      const clerkUser = await clerk.users.getUser(user.clerkId);
      const clerkEmail = clerkUser.emailAddresses.find(
        (e) => e.emailAddress === contact.email,
      );
      if (clerkEmail) {
        await clerk.emailAddresses.updateEmailAddress(clerkEmail.id, {
          primary: true,
        });
      }
    } catch (clerkError) {
      logger.error("Failed to sync primary email to Clerk (non-blocking)", clerkError as Error, {
        user_id: user.id,
        email: contact.email,
      });
    }

    return c.json({ success: true });
  } catch (error) {
    return captureServerError(c, error, "Failed to change primary email", {
      user_id: user.id,
      contact_id: contactId,
    });
  }
});

// DELETE /link-email/:contactId — Remove/unlink an email
linkEmail.delete("/link-email/:contactId", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const contactId = c.req.param("contactId");
  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    // Verify the contact belongs to the current user
    const contact = await c.var.db
      .selectFrom("contact")
      .select(["id", "email", "primary"])
      .where("id", "=", contactId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!contact) {
      return c.json({ error: "Email not found" }, 404);
    }

    // Count how many linked emails the user has
    const countResult = await c.var.db
      .selectFrom("contact")
      .select(c.var.db.fn.countAll<number>().as("count"))
      .where("user_id", "=", user.id)
      .where("email", "is not", null)
      .executeTakeFirstOrThrow();

    if (countResult.count <= 1) {
      return c.json({ error: "Cannot remove your only email address" }, 400);
    }

    if (contact.primary) {
      return c.json({ error: "Cannot remove your primary email address. Make another email primary first." }, 400);
    }

    // Unlink the contact (don't delete it — other data may reference it)
    await c.var.db
      .updateTable("contact")
      .set({ user_id: null, primary: false })
      .where("id", "=", contactId)
      .execute();

    logger.info("Unlinked email from user", {
      user_id: user.id,
      contact_id: contactId,
      email: contact.email,
    });

    // Sync to Clerk: remove this email
    try {
      const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
      const clerkUser = await clerk.users.getUser(user.clerkId);
      const clerkEmail = clerkUser.emailAddresses.find(
        (e) => e.emailAddress === contact.email,
      );
      if (clerkEmail) {
        await clerk.emailAddresses.deleteEmailAddress(clerkEmail.id);
      }
    } catch (clerkError) {
      logger.error("Failed to remove email from Clerk (non-blocking)", clerkError as Error, {
        user_id: user.id,
        email: contact.email,
      });
    }

    return c.json({ success: true });
  } catch (error) {
    return captureServerError(c, error, "Failed to remove linked email", {
      user_id: user.id,
      contact_id: contactId,
    });
  }
});

// POST /link-email/send — Send OTP to the email address the user wants to link
linkEmail.post("/link-email/send", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const body = await c.req.json<{ email?: string }>();
  const email = body.email?.trim().toLowerCase();

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return c.json({ error: "A valid email address is required" }, 400);
  }

  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    // Check if this email's contact is already linked to a user
    const existingContact = await c.var.db
      .selectFrom("contact")
      .select(["id", "user_id"])
      .where("email", "=", email)
      .executeTakeFirst();

    if (existingContact?.user_id) {
      if (existingContact.user_id === user.id) {
        return c.json({ message: "already_linked" });
      }
      return c.json(
        { error: "This email is already linked to another account" },
        409,
      );
    }

    // Clean up expired claims
    await c.var.db
      .deleteFrom("email_claim")
      .where("expires_at", "<", new Date())
      .execute();

    // Generate OTP and upsert claim
    const code = generateOtp();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes

    await c.var.db
      .insertInto("email_claim")
      .values({
        user_id: user.id,
        email,
        code,
        attempts: 0,
        expires_at: expiresAt,
      })
      .onConflict((oc) =>
        oc.constraint("email_claim_user_email_unique").doUpdateSet({
          code,
          attempts: 0,
          expires_at: expiresAt,
        }),
      )
      .execute();

    // Render and send the email
    const { html, text } = await render("link-email", { code });

    const emailResult = await sendEmail(
      {
        from: "Plot <info@updates.plot.day>",
        to: [email],
        subject: "Link this email to your Plot account",
        html,
        text,
      },
      c.env.RESEND_API_KEY,
    );

    if (!emailResult.success) {
      logger.error(
        "Failed to send link-email OTP",
        new Error(emailResult.error ?? "Unknown email error"),
        { user_id: user.id, email },
      );
      return c.json({ error: "Failed to send verification email" }, 500);
    }

    logger.info("Sent link-email OTP", { user_id: user.id, email });
    return c.json({ success: true });
  } catch (error) {
    return captureServerError(c, error, "Failed to send link-email OTP", {
      user_id: user.id,
      email,
    });
  }
});

// POST /link-email/verify — Verify OTP and link the contact + Clerk email
linkEmail.post("/link-email/verify", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const body = await c.req.json<{ email?: string; code?: string }>();
  const email = body.email?.trim().toLowerCase();
  const code = body.code?.trim();

  if (!email || !code) {
    return c.json({ error: "Email and code are required" }, 400);
  }

  const context = extractRequestContext(c);
  const logger = createLogger(context);

  try {
    // Look up the claim
    const claim = await c.var.db
      .selectFrom("email_claim")
      .select(["id", "code", "attempts", "expires_at"])
      .where("user_id", "=", user.id)
      .where("email", "=", email)
      .executeTakeFirst();

    if (!claim) {
      return c.json({ error: "No verification code found. Please request a new one." }, 400);
    }

    if (new Date(claim.expires_at) < new Date()) {
      await c.var.db
        .deleteFrom("email_claim")
        .where("id", "=", claim.id)
        .execute();
      return c.json({ error: "Verification code has expired. Please request a new one." }, 400);
    }

    if (claim.attempts >= 5) {
      return c.json({ error: "Too many attempts. Please request a new code." }, 400);
    }

    if (claim.code !== code) {
      await c.var.db
        .updateTable("email_claim")
        .set({ attempts: claim.attempts + 1 })
        .where("id", "=", claim.id)
        .execute();
      return c.json({ error: "Invalid verification code" }, 400);
    }

    // Code matches — link the contact
    const existingContact = await c.var.db
      .selectFrom("contact")
      .select(["id", "user_id"])
      .where("email", "=", email)
      .executeTakeFirst();

    if (existingContact) {
      if (existingContact.user_id && existingContact.user_id !== user.id) {
        return c.json(
          { error: "This email is already linked to another account" },
          409,
        );
      }
      if (!existingContact.user_id) {
        await c.var.db
          .updateTable("contact")
          .set({ user_id: user.id })
          .where("id", "=", existingContact.id)
          .execute();
        logger.info("Linked existing contact to user", {
          contact_id: existingContact.id,
          user_id: user.id,
          email,
        });
      }
    } else {
      await c.var.db
        .insertInto("contact")
        .values({
          email,
          user_id: user.id,
          name: null,
          avatar_url: null,
          inviteable: classifyInviteable(email, null),
        })
        .execute();
      logger.info("Created new contact for linked email", {
        user_id: user.id,
        email,
      });
    }

    // Sync to Clerk
    await syncContactToClerk(c.env.CLERK_SECRET_KEY, user.clerkId, email, {
      user_id: user.id,
    });

    // Clean up the claim
    await c.var.db
      .deleteFrom("email_claim")
      .where("id", "=", claim.id)
      .execute();

    return c.json({ success: true });
  } catch (error) {
    return captureServerError(c, error, "Failed to verify link-email OTP", {
      user_id: user.id,
      email,
    });
  }
});

export default linkEmail;
