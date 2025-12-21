import { Hono } from "hono";
import { z } from "zod";

import { twistFactory } from "../twist";
import * as twistManagement from "../twist/management";
import type { Bindings } from "../env";
import {
  createFreeSubscription,
  createFreeTierBillingCycle,
  createStripeClient,
  createStripeCustomer,
  getBillingCycleDates,
} from "../stripe/utils";
import { handleValidationError } from "../utils/validation";

const account = new Hono<{ Bindings: Bindings }>();

// Schema for activate request
const ActivateRequestSchema = z.object({
  code: z.string().min(1, "Invitation code is required"),
});

// POST /activate - Activate user account with invitation code
account.post("/activate", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = ActivateRequestSchema.safeParse(rawBody);

  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { code } = parseResult.data;
  const user = c.var.user;

  if (!user) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Step 1: Atomically validate and redeem invitation code
  const { data: redeemResult, error: redeemError } = await c.var.supabase.rpc(
    "redeem_invitation_code",
    {
      invitation_code: code,
      user_id: user.id,
    }
  );

  if (redeemError) {
    console.error("Failed to redeem invitation:", redeemError);
    return new Response("Failed to redeem invitation", { status: 500 });
  }

  if (!(redeemResult as any).success) {
    return c.json(
      { error: "Invalid invitation code or no remaining uses" },
      { status: 400 }
    );
  }

  // Step 2: Generate path for root priority
  const { data: pathData, error: pathError } = await c.var.supabase.rpc(
    "generate_path",
    { parent: null }
  );

  if (pathError || !pathData) {
    console.error("Failed to generate path:", pathError);
    return new Response(
      `Failed to generate path: ${pathError?.message || "Unknown error"}`,
      { status: 500 }
    );
  }

  // Step 3: Create root priority
  const { data: priority, error: priorityError } = await c.var.supabaseAdmin
    .from("priority")
    .insert({
      created_by: user.id,
      title: "Everything",
      path: pathData,
      root: true,
    })
    .select()
    .single();

  if (priorityError || !priority) {
    console.error("Failed to create root priority:", priorityError);
    return new Response(
      `Failed to create root priority: ${
        priorityError?.message || "Unknown error"
      }`,
      { status: 500 }
    );
  }

  // Step 4: Create priority settings
  const { error: settingsError } = await c.var.supabaseAdmin
    .from("priority_settings")
    .insert({
      user_id: user.id,
      priority_id: priority.id,
    });

  if (settingsError) {
    console.error("Failed to create priority settings:", settingsError);
    return new Response(
      `Failed to create priority settings: ${settingsError.message}`,
      { status: 500 }
    );
  }

  // Step 5: Granular Stripe integration with fail-open behavior
  let stripeCustomerId: string | null = null;
  let stripeSubscriptionId: string | null = null;
  let billingStart: Date;
  let billingEnd: Date;

  // Try to create Stripe customer
  try {
    const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);

    const customer = await createStripeCustomer(stripe, {
      userId: user.id,
      email: user.email!,
      name: user.user_metadata?.name,
    });
    stripeCustomerId = customer.id;
    console.log(`Created Stripe customer: ${customer.id}`);

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
      console.log(
        `Created Stripe subscription: ${subscription.id} for customer: ${customer.id}`
      );
    } catch (subscriptionError) {
      console.error(
        "Failed to create Stripe subscription, using local billing cycle:",
        subscriptionError
      );
      // Partial success: customer created but subscription failed
      // Use local billing cycle
      const localDates = createFreeTierBillingCycle();
      billingStart = localDates.start;
      billingEnd = localDates.end;
    }
  } catch (customerError) {
    console.error(
      "Failed to create Stripe customer, proceeding without Stripe:",
      customerError
    );

    // Complete failure: no Stripe integration
    // Use local billing cycle
    const localDates = createFreeTierBillingCycle();
    billingStart = localDates.start;
    billingEnd = localDates.end;
  }

  // Step 6: Insert user_subscription record with whatever Stripe data we have
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
    console.error("Failed to create user_subscription:", subscriptionError);
    return new Response(
      `Failed to create subscription record: ${subscriptionError.message}`,
      { status: 400 }
    );
  }

  // Step 7: Install and activate Plot twist
  try {
    const { data: plotTwist, error: plotTwistError } = await c.var.supabase
      .from("twist")
      .select("id,version")
      .eq("id", "0199b6f4-ae64-7718-8a02-44716f30358f")
      .eq("environment", "public")
      .maybeSingle();

    if (plotTwistError) {
      throw new Error(
        `Plot twist not found: ${plotTwistError?.message || "Unknown error"}`
      );
    }

    if (plotTwist) {
      await twistManagement.add(
        c.var.supabase,
        c.var.supabaseAdmin,
        priority.id,
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
    } else {
      console.warn("Plot twist not found, skipping installation.");
    }
  } catch (error) {
    console.error("Failed to add Plot twist:", error);
  }

  // Step 8: Set user status to active
  const { error: statusError } = await c.var.supabase.rpc("set_user_status", {
    user_id: user.id,
    status: "active",
  });

  if (statusError) {
    console.error("Failed to set user status:", statusError);
    return new Response(`Failed to set user status: ${statusError.message}`, {
      status: 500,
    });
  }

  return c.json({ success: true });
});

// DELETE /account - Delete user account
account.delete("/", async (c) => {
  const user = c.var.user;

  if (!user) {
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    // Step 1: Get user subscription to find Stripe info
    const { data: subscription, error: subError } = await c.var.supabase
      .from("user_subscription")
      .select("stripe_subscription_id")
      .eq("user_id", user.id)
      .maybeSingle();

    if (subError) {
      console.error("Failed to fetch user subscription:", subError);
    }

    // Step 2: Cancel Stripe subscription if it exists
    if (subscription?.stripe_subscription_id) {
      try {
        const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
        await stripe.subscriptions.cancel(subscription.stripe_subscription_id);
        console.log(
          `Canceled Stripe subscription: ${subscription.stripe_subscription_id}`
        );
      } catch (stripeError) {
        console.error("Failed to cancel Stripe subscription:", stripeError);
        // Continue with deletion even if Stripe fails
      }
    }

    // Step 3: Ban the user account for 14 days
    // Set banned_until to 14 days from now
    const bannedUntil = new Date();
    bannedUntil.setDate(bannedUntil.getDate() + 14);

    const { error: banError } = await c.var.supabaseAdmin.auth.admin.updateUserById(
      user.id,
      {
        ban_duration: "336h", // 14 days in hours
      }
    );

    if (banError) {
      console.error("Failed to ban user:", banError);
      // Continue with other deletion steps
    }

    // Step 4: Set user status to deleted
    const { error: statusError } = await c.var.supabase.rpc("set_user_status", {
      user_id: user.id,
      status: "deleted",
    });

    if (statusError) {
      console.error("Failed to set user status:", statusError);
    }

    // Step 5: Send notification email to team@plot.day
    try {
      await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${c.env.RESEND_API_KEY}`,
        },
        body: JSON.stringify({
          from: "Plot <info@updates.plot.day>",
          to: ["team@plot.day"],
          subject: "Account Deletion Request",
          html: `
            <h2>Account Deletion Request</h2>
            <p>A user has requested account deletion:</p>
            <ul>
              <li><strong>User ID:</strong> ${user.id}</li>
              <li><strong>Email:</strong> ${user.email}</li>
              <li><strong>Deletion Requested:</strong> ${new Date().toISOString()}</li>
              <li><strong>Permanent Deletion Scheduled:</strong> ${bannedUntil.toISOString()}</li>
            </ul>
            <p>The account has been deactivated. Please complete manual data deletion within 14 days.</p>
          `,
          text: `
Account Deletion Request

A user has requested account deletion:
- User ID: ${user.id}
- Email: ${user.email}
- Deletion Requested: ${new Date().toISOString()}
- Permanent Deletion Scheduled: ${bannedUntil.toISOString()}

The account has been deactivated. Please complete manual data deletion within 14 days.
          `,
        }),
      });
    } catch (emailError) {
      console.error("Failed to send notification email:", emailError);
      // Don't fail the request if email fails
    }

    return c.json({ success: true });
  } catch (error) {
    console.error("Account deletion error:", error);
    return new Response("Failed to delete account", { status: 500 });
  }
});

export default account;
