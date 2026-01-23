import * as crypto from "crypto";

import { type EmailType, render } from "@plotday/email";
import type { SupabaseClient } from "@supabase/supabase-js";
import { Hono } from "hono";

import type { Bindings } from "../env";
import {
  createFreeSubscription,
  createFreeTierBillingCycle,
  createStripeClient,
  createStripeCustomer,
  getBillingCycleDates,
} from "../stripe/utils";
import { twistFactory } from "../twist";
import * as twistManagement from "../twist/management";
import { captureServerError } from "../utils/error-capture";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";

interface SendInvitationParams {
  contactId: string;
  priorityId: string;
  inviterUserId: string;
  resendApiKey: string;
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
  supabaseAdmin: SupabaseClient,
  params: SendInvitationParams
): Promise<SendInvitationResult> {
  const { contactId, priorityId, inviterUserId, resendApiKey } = params;

  // 1. Get contact info
  const { data: contact, error: contactError } = await supabaseAdmin
    .from("contact")
    .select("id, email, name")
    .eq("id", contactId)
    .single();

  if (contactError || !contact) {
    return { success: false, error: "contact_not_found" };
  }

  // 2. Get or create invitation token
  const newToken = crypto.randomBytes(32).toString("hex");
  const { data: tokenResult, error: tokenError } = await supabaseAdmin.rpc(
    "get_invitation_token",
    {
      p_contact_id: contactId,
      p_new_token: newToken,
    }
  );

  if (tokenError) {
    return { success: false, error: tokenError.message };
  }

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
      return { success: true, skipped: true };
    }
  }

  // 4. Get inviter and priority info for email
  const [inviterResult, priorityResult] = await Promise.all([
    supabaseAdmin
      .from("contact")
      .select("name, email")
      .eq("user_id", inviterUserId)
      .single(),
    supabaseAdmin.from("priority").select("title").eq("id", priorityId).single(),
  ]);

  const inviterName =
    inviterResult.data?.name || inviterResult.data?.email || "Someone";
  const priorityName = priorityResult.data?.title || "a priority";

  // 5. Render and send email via Resend
  const inviteUrl = `https://plot.day/join?invite=${token}`;
  const { html, text } = render("priority-invitation" as EmailType, {
    inviterName,
    priorityName,
    inviteUrl,
    recipientName: contact.name || undefined,
  });

  const emailResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "Plot <info@updates.plot.day>",
      reply_to: "Plot <team@plot.day>",
      to: [contact.email],
      subject: `${inviterName} invited you to collaborate on Plot`,
      html,
      text,
    }),
  });

  if (!emailResponse.ok) {
    const errorBody = await emailResponse.text();
    console.error("Failed to send invitation email:", errorBody);
    return { success: false, error: "email_send_failed" };
  }

  // 6. Update sent_at timestamp (for existing tokens)
  if (!is_new) {
    await supabaseAdmin.rpc("update_invitation_sent_at", {
      p_contact_id: contactId,
    });
  }

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
  supabaseAdmin: SupabaseClient,
  userId: string,
  token: string
): Promise<RedeemInvitationResult> {
  const { data, error } = await supabaseAdmin.rpc("redeem_invitation_token", {
    p_user_id: userId,
    p_token: token,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return data as RedeemInvitationResult;
}

// Hono router for invitation endpoints
const invitation = new Hono<{ Bindings: Bindings }>();

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

  const result = await redeemInvitation(c.var.supabaseAdmin, user.id, token);

  if (!result.success) {
    // Return appropriate status based on error
    if (result.error === "invalid_token") {
      return c.json({ success: false, error: "invalid_token" }, 404);
    }
    if (result.error === "contact_linked_to_other_user") {
      return c.json({ success: false, error: "contact_linked_to_other_user" }, 409);
    }
    return c.json({ success: false, error: result.error }, 500);
  }

  // After successful redemption, check if user was activated
  // Get the root priority for this user to perform additional setup
  const { data: rootPriorityUser, error: rootPriorityError } =
    await c.var.supabaseAdmin
      .from("priority_user")
      .select("priority_id")
      .eq("user_id", user.id)
      .eq("personal", true)
      .maybeSingle();

  if (rootPriorityError) {
    return captureServerError(c, new Error(rootPriorityError.message), `Failed to check for root priority: ${rootPriorityError.message}`, {
      user_id: user.id,
    });
  }

  // If a root priority exists, perform Stripe and Plot twist setup
  if (rootPriorityUser) {
    const rootPriorityId = rootPriorityUser.priority_id;

    // Check if user_subscription already exists (skip if already set up)
    const { data: existingSubscription, error: subscriptionCheckError } =
      await c.var.supabaseAdmin
        .from("user_subscription")
        .select("user_id")
        .eq("user_id", user.id)
        .maybeSingle();

    if (subscriptionCheckError) {
      return captureServerError(c, new Error(subscriptionCheckError.message), `Failed to check for existing subscription: ${subscriptionCheckError.message}`, {
        user_id: user.id,
      });
    }

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
          email: user.email!,
          name: user.user_metadata?.name,
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
          logger3.error("Failed to create Stripe subscription, using local billing cycle", subscriptionError as Error, {
            customer_id: customer.id,
            user_id: user.id,
          });
          // Partial success: customer created but subscription failed
          // Use local billing cycle
          const localDates = createFreeTierBillingCycle();
          billingStart = localDates.start;
          billingEnd = localDates.end;
        }
      } catch (customerError) {
        const context4 = extractRequestContext(c);
        const logger4 = createLogger(context4);
        logger4.error("Failed to create Stripe customer, proceeding without Stripe", customerError as Error, {
          user_id: user.id,
        });

        // Complete failure: no Stripe integration
        // Use local billing cycle
        const localDates = createFreeTierBillingCycle();
        billingStart = localDates.start;
        billingEnd = localDates.end;
      }

      // Insert user_subscription record with whatever Stripe data we have
      const { error: subscriptionError } = await c.var.supabaseAdmin
        .from("user_subscription")
        .insert({
          user_id: user.id,
          stripe_customer_id: stripeCustomerId,
          stripe_subscription_id: stripeSubscriptionId,
          plan: "free",
          status: "active",
          billing_cycle_start: billingStart.toISOString(),
          billing_cycle_end: billingEnd.toISOString(),
        });

      if (subscriptionError) {
        const context5 = extractRequestContext(c);
        const logger5 = createLogger(context5);
        logger5.error("Failed to create user_subscription for invited user", new Error(subscriptionError.message), {
          user_id: user.id,
        });
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
      const { data: plotTwist, error: plotTwistError } = await c.var.supabase
        .from("twist")
        .select("id,version")
        .eq("name", "Plot")
        .eq("environment", "public")
        .is("archived_at", null)
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();

      if (plotTwistError) {
        throw new Error(
          `Plot twist not found: ${plotTwistError?.message || "Unknown error"}`
        );
      }

      if (plotTwist) {
        // Check if Plot twist is already installed
        const { data: existingInstallation } = await c.var.supabaseAdmin
          .from("priority_twist")
          .select("id")
          .eq("priority_id", rootPriorityId)
          .eq("twist_id", plotTwist.id)
          .is("archived_at", null)
          .maybeSingle();

        if (!existingInstallation) {
          await twistManagement.add(
            c.var.supabase,
            c.var.supabaseAdmin,
            rootPriorityId,
            plotTwist.id,
            "public",
            "Plot",
            undefined,
            {
              twistFactory: twistFactory({
                env: c.env,
                ctx: c.executionCtx as ExecutionContext,
                supabase: c.var.supabaseAdmin,
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
      } else {
        const context9 = extractRequestContext(c);
        const logger9 = createLogger(context9);
        logger9.warn("Plot twist not found, skipping installation");
      }
    } catch (error) {
      const context10 = extractRequestContext(c);
      const logger10 = createLogger(context10);
      logger10.error("Failed to add Plot twist for invited user", error as Error, {
        priority_id: rootPriorityId,
        user_id: user.id,
      });
      // Don't fail the request - log the error but continue
    }
  }

  return c.json(result);
});

export default invitation;
