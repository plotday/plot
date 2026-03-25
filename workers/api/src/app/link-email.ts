import { Hono } from "hono";
import { createClerkClient } from "@clerk/backend";

import { render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { sendEmail } from "../email/send";
import { captureServerError } from "../utils/error-capture";
import { extractRequestContext } from "../utils/log-context";

const linkEmail = new Hono<{ Bindings: Bindings }>();

/** Generate a 6-digit numeric OTP code. */
function generateOtp(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

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
      // Clean up expired claim
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
      // Increment attempts
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
        // Race condition: another user claimed this email between send and verify
        return c.json(
          { error: "This email is already linked to another account" },
          409,
        );
      }
      if (!existingContact.user_id) {
        // Unclaimed contact — link it
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
      // else: already linked to this user — no-op
    } else {
      // No contact exists — create one
      await c.var.db
        .insertInto("contact")
        .values({
          email,
          user_id: user.id,
          name: null,
          avatar_url: null,
        })
        .execute();
      logger.info("Created new contact for linked email", {
        user_id: user.id,
        email,
      });
    }

    // Add verified email to Clerk user so they can sign in with it
    try {
      const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
      await clerk.emailAddresses.createEmailAddress({
        userId: user.clerkId,
        emailAddress: email,
        verified: true,
      });
      logger.info("Added verified email to Clerk user", {
        user_id: user.id,
        clerk_id: user.clerkId,
        email,
      });
    } catch (clerkError) {
      // Log but don't fail — the contact is already linked in our DB.
      // Common case: email already exists on this Clerk user.
      logger.error(
        "Failed to add email to Clerk (non-blocking)",
        clerkError as Error,
        { user_id: user.id, clerk_id: user.clerkId, email },
      );
    }

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
