import * as crypto from "crypto";
import type { Kysely } from "kysely";
import { Hono } from "hono";

import { render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { rpc } from "../rpc";
import {
  createFreeSubscription,
  createFreeTierBillingCycle,
  createStripeClient,
  createStripeCustomer,
  getBillingCycleDates,
} from "../stripe/utils";
import { twistFactory } from "../twist";
import * as twistManagement from "../twist/management";
import { extractRequestContext } from "../utils/log-context";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

interface SendInvitationParams {
  contactId: string;
  priorityId: string;
  inviterUserId: string;
  mailQueue: Queue<{
    to: string[];
    subject: string;
    email: string;
    props?: Record<string, unknown>;
  }>;
  appRoot: string;
}

interface SendInvitationResult {
  success: boolean;
  error?: string;
  skipped?: boolean;
}

interface RedeemInvitationResult {
  success: boolean;
  error?: string;
  contactId?: string;
  already_redeemed?: boolean;
}

/**
 * Send an invitation email to a contact for a priority.
 *
 * This function:
 * 1. Gets or creates an invitation token for the contact
 * 2. Checks if we should skip sending (sent within last 24 hours)
 * 3. Sends the email with a secure invitation link
 * 4. Updates the sent_at timestamp
 */
export async function sendInvitation(
  db: Kysely<DB>,
  params: SendInvitationParams
): Promise<SendInvitationResult> {
  const { contactId, priorityId, inviterUserId, mailQueue, appRoot } = params;

  const logger = createLogger({ component: "invitation" });
  logger.info("Starting invitation process", {
    contact_id: contactId,
    priority_id: priorityId,
  });

  // 1. Get contact info
  const contact = await db
    .selectFrom("contact")
    .select(["id", "email", "name"])
    .where("id", "=", contactId)
    .executeTakeFirst();

  if (!contact) {
    logger.error(
      "Contact not found",
      new Error("Contact not found"),
      { contact_id: contactId }
    );
    return { success: false, error: "contact_not_found" };
  }

  logger.info("Found contact", { contact_email: contact.email });

  // 2. Get or create invitation token
  const newToken = crypto.randomBytes(32).toString("hex");
  const tokenResult = await rpc(db, "get_invitation_token", {
    p_contact_id: contactId,
    p_new_token: newToken,
  });

  const { token, sent_at, is_new } = tokenResult as {
    token: string;
    sent_at: string;
    is_new: boolean;
  };

  // 3. Check if we should skip sending (sent within last 24 hours)
  if (!is_new && sent_at) {
    const sentAt = new Date(sent_at);
    const hoursSince = (Date.now() - sentAt.getTime()) / (1000 * 60 * 60);
    if (hoursSince < 24) {
      logger.info("Skipping invitation - already sent recently", {
        hours_since: hoursSince.toFixed(1),
        contact_email: contact.email,
      });
      return { success: true, skipped: true };
    }
  }

  // 4. Get inviter and priority info for email
  const [inviterResult, priorityResult] = await Promise.all([
    db
      .selectFrom("user")
      .select(["name", "email"])
      .where("id", "=", inviterUserId)
      .executeTakeFirst(),
    db
      .selectFrom("priority")
      .select("title")
      .where("id", "=", priorityId)
      .executeTakeFirst(),
  ]);

  const inviterName =
    inviterResult?.name ||
    inviterResult?.email?.split("@")[0] ||
    "Someone";
  const priorityName = priorityResult?.title || "a priority";

  // 5. Send invitation email
  const inviteUrl = `${appRoot}/invite/${token}`;
  const emailSubject = `${inviterName} is inviting you to Plot`;
  const emailProps = {
    inviterName,
    priorityName,
    inviteUrl,
    recipientName: contact.name || undefined,
  };

  if (!contact.email) {
    logger.error("Cannot send invitation to contact without email", {
      contact_id: contact.id,
    });
    return { success: false, error: "Contact has no email address" };
  }

  logger.info("Sending invitation email", {
    contact_email: contact.email,
    priority_name: priorityName,
    inviter_name: inviterName,
  });

  // In development, bypass the queue and send directly to Mailpit.
  // Cloudflare Queues in wrangler dev don't reliably deliver messages.
  const isDevelopment = typeof ENV !== "undefined" && ENV === "development";

  try {
    if (isDevelopment) {
      const { html, text } = await render("priority-invitation", emailProps);
      const response = await fetch("http://127.0.0.1:54324/api/v1/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          From: { Name: "Plot", Email: "info@updates.plot.day" },
          To: [{ Email: contact.email }],
          Subject: emailSubject,
          HTML: html,
          Text: text,
          ReplyTo: [{ Name: "Plot", Email: "team@plot.day" }],
        }),
      });
      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Mailpit send failed: ${errorText}`);
      }
      logger.info("Sent invitation email via Mailpit", {
        contact_email: contact.email,
      });
    } else {
      await mailQueue.send({
        to: [contact.email],
        subject: emailSubject,
        email: "priority-invitation",
        props: emailProps,
      });
      logger.info("Queued invitation email", {
        contact_email: contact.email,
      });
    }
  } catch (error) {
    logger.error("Failed to send invitation email", error as Error, {
      contact_email: contact.email,
    });
    return {
      success: false,
      error: error instanceof Error ? error.message : "email_send_failed",
    };
  }

  // Update sent_at so the 24-hour cooldown starts at queue-time
  await rpc(db, "update_invitation_sent_at", {
    p_contact_id: contactId,
  });

  return { success: true };
}

/**
 * Redeem an invitation token after a user signs up or signs in.
 *
 * This function:
 * 1. Links the contact to the user (if not already linked)
 * 2. Accepts pending priority_invitations for this contact
 * 3. Deletes the token (one-time use)
 */
export async function redeemInvitation(
  db: Kysely<DB>,
  userId: string,
  token: string
): Promise<RedeemInvitationResult> {
  const data = await rpc(db, "redeem_invitation_token", {
    p_user_id: userId,
    p_token: token,
  });

  return data as unknown as RedeemInvitationResult;
}

// Hono router for invitation endpoints
const invitation = new Hono<{ Bindings: Bindings }>();

// GET /invitation/:token - Look up invitation details by token
invitation.get("/invitation/:token", async (c) => {
  const token = c.req.param("token");

  if (!token || typeof token !== "string") {
    return c.json({ message: "Token required" }, 400);
  }

  try {
    const data = await c.var.db
      .selectFrom("contact_invitation")
      .innerJoin("contact", "contact.id", "contact_invitation.contact_id")
      .select(["contact_invitation.contact_id", "contact.email"])
      .where("contact_invitation.token", "=", token)
      .executeTakeFirst();

    if (!data) {
      return c.json({ message: "Invalid or expired invitation" }, 404);
    }

    // Look up inviter name via priority_contact.invited_by
    let inviterName: string | null = null;
    try {
      const pc = await c.var.db
        .selectFrom("priority_contact")
        .select("invited_by")
        .where("contact_id", "=", data.contact_id)
        .where("invited_by", "is not", null)
        .limit(1)
        .executeTakeFirst();

      if (pc?.invited_by) {
        const inviter = await c.var.db
          .selectFrom("user")
          .select(["name", "email"])
          .where("id", "=", pc.invited_by)
          .executeTakeFirst();
        inviterName =
          inviter?.name ||
          inviter?.email?.split("@")[0] ||
          null;
      }
    } catch {
      // Non-critical: return response without inviter name
    }

    return c.json({ email: data.email, inviterName });
  } catch (error) {
    const logger = createLogger({ component: "invitation" });
    logger.error(
      "Failed to look up invitation token",
      error as Error,
      { token }
    );
    return c.json({ message: "Internal error" }, 500);
  }
});

// POST /invitation/redeem - Redeem an invitation token after auth
invitation.post("/invitation/redeem", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const body = await c.req.json<{ token?: string }>();
  const token = body?.token;

  if (!token || typeof token !== "string") {
    return c.json({ message: "Token required" }, 400);
  }

  const result = await redeemInvitation(c.var.db, user.id, token);

  if (result.success) {
    c.var.tracker.capture("[Action] Invitation Accepted", {
      priorities_joined: (result as any).priorities?.length ?? 0,
    });
  }

  if (!result.success) {
    // Return appropriate status based on error
    if (result.error === "invalid_token") {
      return c.json({ success: false, error: "invalid_token" }, 404);
    }
    if (result.error === "already_redeemed_by_different_user") {
      return c.json(
        { success: false, error: "already_redeemed_by_different_user" },
        409
      );
    }
    if (result.error === "contact_linked_to_other_user") {
      return c.json(
        { success: false, error: "contact_linked_to_other_user" },
        409
      );
    }
    return c.json({ success: false, error: result.error }, 500);
  }

  // Get the root priority for this user to perform additional setup
  const rootPriorityUser = await c.var.db
    .selectFrom("priority_user")
    .select("priority_id")
    .where("user_id", "=", user.id)
    .where("personal", "=", true)
    .executeTakeFirst();

  // If a root priority exists, perform Stripe and Plot twist setup
  if (rootPriorityUser) {
    const rootPriorityId = rootPriorityUser.priority_id;

    // Check if user_subscription already exists (skip if already set up)
    const existingSubscription = await c.var.db
      .selectFrom("user_subscription")
      .select("user_id")
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    // Only set up Stripe if subscription doesn't exist
    if (!existingSubscription) {
      let stripeCustomerId: string | null = null;
      let stripeSubscriptionId: string | null = null;
      let billingStart: Date;
      let billingEnd: Date;

      // Try to create Stripe customer (fail-open)
      try {
        const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);

        const customer = await createStripeCustomer(stripe, {
          userId: user.id,
          email: user.email,
          name: user.name ?? undefined,
        });
        stripeCustomerId = customer.id;
        const context1 = extractRequestContext(c);
        const logger1 = createLogger(context1);
        logger1.info("Created Stripe customer for invited user", {
          customer_id: customer.id,
          user_id: user.id,
        });

        // Try to create free subscription (only if customer created)
        try {
          const subscription = await createFreeSubscription(stripe, {
            customerId: customer.id,
            userId: user.id,
          });
          stripeSubscriptionId = subscription.id;
          const dates = getBillingCycleDates(subscription);
          billingStart = dates.start;
          billingEnd = dates.end;
          const context2 = extractRequestContext(c);
          const logger2 = createLogger(context2);
          logger2.info("Created Stripe subscription for invited user", {
            subscription_id: subscription.id,
            customer_id: customer.id,
            user_id: user.id,
          });
        } catch (subscriptionError) {
          const context3 = extractRequestContext(c);
          const logger3 = createLogger(context3);
          logger3.error(
            "Failed to create Stripe subscription, using local billing cycle",
            subscriptionError as Error,
            {
              customer_id: customer.id,
              user_id: user.id,
            }
          );
          // Partial success: customer created but subscription failed
          // Use local billing cycle
          const localDates = createFreeTierBillingCycle();
          billingStart = localDates.start;
          billingEnd = localDates.end;
        }
      } catch (customerError) {
        const context4 = extractRequestContext(c);
        const logger4 = createLogger(context4);
        logger4.error(
          "Failed to create Stripe customer, proceeding without Stripe",
          customerError as Error,
          {
            user_id: user.id,
          }
        );

        // Complete failure: no Stripe integration
        // Use local billing cycle
        const localDates = createFreeTierBillingCycle();
        billingStart = localDates.start;
        billingEnd = localDates.end;
      }

      // Insert user_subscription record with whatever Stripe data we have
      try {
        await c.var.db
          .insertInto("user_subscription")
          .values({
            user_id: user.id,
            stripe_customer_id: stripeCustomerId,
            stripe_subscription_id: stripeSubscriptionId,
            plan: "free",
            status: "active",
            billing_cycle_start: billingStart!.toISOString(),
            billing_cycle_end: billingEnd!.toISOString(),
          })
          .execute();
      } catch (subscriptionError) {
        const context5 = extractRequestContext(c);
        const logger5 = createLogger(context5);
        logger5.error(
          "Failed to create user_subscription for invited user",
          subscriptionError as Error,
          {
            user_id: user.id,
          }
        );
        // Don't fail the request - log the error but continue
      }
    } else {
      const context6 = extractRequestContext(c);
      const logger6 = createLogger(context6);
      logger6.info("User subscription already exists, skipping Stripe setup", {
        user_id: user.id,
      });
    }

    // Install Plot twist on root priority (if not already installed)
    try {
      const plotTwist = await c.var.db
        .selectFrom("twist")
        .select(["id", "version"])
        .where("name", "=", "Plot")
        .where("environment", "=", "public")
        .where("archived_at", "is", null)
        .orderBy("created_at", "asc")
        .limit(1)
        .executeTakeFirst();

      if (!plotTwist) {
        const context9 = extractRequestContext(c);
        const logger9 = createLogger(context9);
        logger9.warn("Plot twist not found, skipping installation");
      } else {
        // Check if Plot twist is already installed
        const existingInstallation = await c.var.db
          .selectFrom("priority_twist")
          .select("id")
          .where("priority_id", "=", rootPriorityId)
          .where("twist_id", "=", plotTwist.id)
          .where("archived_at", "is", null)
          .executeTakeFirst();

        if (!existingInstallation) {
          await twistManagement.add(
            c.var.db,
            user.id,
            rootPriorityId,
            Number(plotTwist.id),
            "public",
            "Plot",
            undefined,
            {
              twistFactory: twistFactory({
                env: c.env,
                ctx: c.executionCtx as ExecutionContext,
                db: c.var.db,
              }),
              version: plotTwist.version,
            }
          );
          const context7 = extractRequestContext(c);
          const logger7 = createLogger(context7);
          logger7.info("Installed Plot twist for invited user", {
            priority_id: rootPriorityId,
            user_id: user.id,
          });
        } else {
          const context8 = extractRequestContext(c);
          const logger8 = createLogger(context8);
          logger8.info("Plot twist already installed, skipping", {
            priority_id: rootPriorityId,
            user_id: user.id,
          });
        }
      }
    } catch (error) {
      const context10 = extractRequestContext(c);
      const logger10 = createLogger(context10);
      logger10.error(
        "Failed to add Plot twist for invited user",
        error as Error,
        {
          priority_id: rootPriorityId,
          user_id: user.id,
        }
      );
      // Don't fail the request - log the error but continue
    }
  }

  return c.json(result);
});

export default invitation;
