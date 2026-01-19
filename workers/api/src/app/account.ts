import { Hono } from "hono";
import { z } from "zod";

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
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";
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
    return c.json({ message: "Unauthorized" }, 401);
  }

  // Step 1: Atomically validate and redeem invitation code
  // Using supabaseAdmin since function is revoked from authenticated
  const { data: redeemResult, error: redeemError } = await c.var.supabaseAdmin.rpc(
    "redeem_invitation_code",
    {
      invitation_code: code,
      user_id: user.id,
    }
  );

  if (redeemError) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to redeem invitation", new Error(redeemError.message), {
      invitation_code: code,
      user_id: user.id,
    });
    return c.json({ message: "Failed to redeem invitation" }, 500);
  }

  if (!(redeemResult as any).success) {
    return c.json(
      { message: "Invalid invitation code or no remaining uses" },
      400
    );
  }

  // Step 2: Check if root priority already exists
  const { data: existingPriorityUser, error: existingPriorityError } =
    await c.var.supabaseAdmin
      .from("priority_user")
      .select("priority_id")
      .eq("user_id", user.id)
      .eq("personal", true)
      .maybeSingle();

  if (existingPriorityError) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to check for existing priority", new Error(existingPriorityError.message), {
      user_id: user.id,
    });
    return c.json(
      {
        message: `Failed to check for existing priority: ${existingPriorityError.message}`,
      },
      500
    );
  }

  let priority: { id: string } | null = null;
  let shouldInstallPlotTwist = true;

  if (existingPriorityUser) {
    // Root priority already exists (e.g., from generate-seed script)
    // Skip creating it and skip Plot twist installation
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Root priority already exists, skipping creation and Plot twist installation", {
      user_id: user.id,
      priority_id: existingPriorityUser.priority_id,
    });
    priority = { id: existingPriorityUser.priority_id };
    shouldInstallPlotTwist = false;
  } else {
    // Step 3: Generate path for root priority
    const { data: pathData, error: pathError } = await c.var.supabase.rpc(
      "generate_path",
      { parent: null }
    );

    if (pathError || !pathData) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to generate path", pathError ? new Error(pathError.message) : new Error("Unknown error"));
      return c.json(
        {
          message: `Failed to generate path: ${
            pathError?.message || "Unknown error"
          }`,
        },
        500
      );
    }

    // Step 4: Create root priority
    const { data: newPriority, error: priorityError } =
      await c.var.supabaseAdmin
        .from("priority")
        .insert({
          created_by: user.id,
          title: "Everything",
          path: pathData,
          color: 0,
        })
        .select()
        .single();

    if (priorityError || !newPriority) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to create root priority", priorityError ? new Error(priorityError.message) : new Error("Unknown error"), {
        user_id: user.id,
      });
      return c.json(
        {
          message: `Failed to create root priority: ${
            priorityError?.message || "Unknown error"
          }`,
        },
        500
      );
    }

    // Step 4.5: Mark the priority_user entry as root
    // The insert_priority_user trigger already created a priority_user entry
    const { error: keyError } = await c.var.supabaseAdmin
      .from("priority_user")
      .update({ personal: true })
      .eq("user_id", user.id)
      .eq("priority_id", newPriority.id);

    if (keyError) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to set personal flag on priority_user", new Error(keyError.message), {
        user_id: user.id,
        priority_id: newPriority.id,
      });
      return c.json(
        {
          message: `Failed to set personal flag: ${keyError.message}`,
        },
        500
      );
    }

    priority = newPriority;
  }

  // Step 4: Create priority settings (if they don't exist)
  const { data: existingSettings, error: existingSettingsError } =
    await c.var.supabaseAdmin
      .from("priority_settings")
      .select("user_id")
      .eq("user_id", user.id)
      .eq("priority_id", priority.id)
      .maybeSingle();

  if (existingSettingsError) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to check for existing priority settings", new Error(existingSettingsError.message), {
      user_id: user.id,
      priority_id: priority.id,
    });
    return c.json(
      {
        message: `Failed to check for existing priority settings: ${existingSettingsError.message}`,
      },
      500
    );
  }

  if (!existingSettings) {
    const { error: settingsError } = await c.var.supabaseAdmin
      .from("priority_settings")
      .insert({
        user_id: user.id,
        priority_id: priority.id,
      });

    if (settingsError) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to create priority settings", new Error(settingsError.message), {
        user_id: user.id,
        priority_id: priority.id,
      });
      return c.json(
        {
          message: `Failed to create priority settings: ${settingsError.message}`,
        },
        500
      );
    }
  } else {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Priority settings already exist, skipping creation", {
      user_id: user.id,
      priority_id: priority.id,
    });
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
    const context1 = extractRequestContext(c);
    const logger1 = createLogger(context1);
    logger1.info("Created Stripe customer", {
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
      logger2.info("Created Stripe subscription", {
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
    const context5 = extractRequestContext(c);
    const logger5 = createLogger(context5);
    logger5.error("Failed to create user_subscription", new Error(subscriptionError.message), {
      user_id: user.id,
    });
    return c.json(
      {
        message: `Failed to create subscription record: ${subscriptionError.message}`,
      },
      400
    );
  }

  // Step 7: Create Plot priority (skip if root priority already existed)
  let _plotPriority: { id: string } | null = null;
  if (shouldInstallPlotTwist) {
    // Generate path for Plot priority as child of root
    const { data: plotPathData, error: plotPathError } = await c.var.supabase.rpc(
      "generate_path",
      { parent: (priority as any).path || priority.id }
    );

    if (plotPathError || !plotPathData) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to generate path for Plot priority", plotPathError ? new Error(plotPathError.message) : new Error("Unknown error"));
      return c.json(
        {
          message: `Failed to generate path for Plot priority: ${
            plotPathError?.message || "Unknown error"
          }`,
        },
        500
      );
    }

    // Create Plot priority
    const { data: newPlotPriority, error: plotPriorityError } =
      await c.var.supabaseAdmin
        .from("priority")
        .insert({
          created_by: user.id,
          title: "Plot",
          path: plotPathData,
          color: 0,
          key: "@plot",
        })
        .select()
        .single();

    if (plotPriorityError || !newPlotPriority) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.error("Failed to create Plot priority", plotPriorityError ? new Error(plotPriorityError.message) : new Error("Unknown error"), {
        user_id: user.id,
      });
      return c.json(
        {
          message: `Failed to create Plot priority: ${
            plotPriorityError?.message || "Unknown error"
          }`,
        },
        500
      );
    }

    _plotPriority = newPlotPriority;
  }

  // Step 8: Install and activate Plot twist on root priority (skip if root priority already existed)
  if (shouldInstallPlotTwist && priority) {
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
        const context6 = extractRequestContext(c);
        const logger6 = createLogger(context6);
        logger6.warn("Plot twist not found, skipping installation");
      }
    } catch (error) {
      const context7 = extractRequestContext(c);
      const logger7 = createLogger(context7);
      logger7.error("Failed to add Plot twist", error as Error, {
        priority_id: priority.id,
        user_id: user.id,
      });
    }
  } else {
    const context8 = extractRequestContext(c);
    const logger8 = createLogger(context8);
    logger8.info("Skipping Plot twist installation (root priority already existed)", {
      user_id: user.id,
      priority_id: priority.id,
    });
  }

  // Step 9: Set user status to active
  // Using supabaseAdmin since function is revoked from authenticated
  const { error: statusError } = await c.var.supabaseAdmin.rpc("set_user_status", {
    user_id: user.id,
    status: "active",
  });

  if (statusError) {
    const context9 = extractRequestContext(c);
    const logger9 = createLogger(context9);
    logger9.error("Failed to set user status", new Error(statusError.message), {
      user_id: user.id,
      status: "active",
    });
    return c.json(
      { message: `Failed to set user status: ${statusError.message}` },
      500
    );
  }

  return c.json({ success: true });
});

// DELETE /account - Delete user account
account.delete("/", async (c) => {
  const user = c.var.user;

  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  try {
    // Step 1: Get user subscription to find Stripe info
    const { data: subscription, error: subError } = await c.var.supabase
      .from("user_subscription")
      .select("stripe_subscription_id")
      .eq("user_id", user.id)
      .maybeSingle();

    if (subError) {
      const context10 = extractRequestContext(c);
      const logger10 = createLogger(context10);
      logger10.error("Failed to fetch user subscription", new Error(subError.message), {
        user_id: user.id,
      });
    }

    // Step 2: Cancel Stripe subscription if it exists
    if (subscription?.stripe_subscription_id) {
      try {
        const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
        await stripe.subscriptions.cancel(subscription.stripe_subscription_id);
        const context11 = extractRequestContext(c);
        const logger11 = createLogger(context11);
        logger11.info("Canceled Stripe subscription", {
          subscription_id: subscription.stripe_subscription_id,
          user_id: user.id,
        });
      } catch (stripeError) {
        const context12 = extractRequestContext(c);
        const logger12 = createLogger(context12);
        logger12.error("Failed to cancel Stripe subscription", stripeError as Error, {
          subscription_id: subscription.stripe_subscription_id,
          user_id: user.id,
        });
        // Continue with deletion even if Stripe fails
      }
    }

    // Step 3: Ban the user account for 14 days
    // Set banned_until to 14 days from now
    const bannedUntil = new Date();
    bannedUntil.setDate(bannedUntil.getDate() + 14);

    const { error: banError } =
      await c.var.supabaseAdmin.auth.admin.updateUserById(user.id, {
        ban_duration: "336h", // 14 days in hours
      });

    if (banError) {
      const context13 = extractRequestContext(c);
      const logger13 = createLogger(context13);
      logger13.error("Failed to ban user", new Error(banError.message), {
        user_id: user.id,
      });
      // Continue with other deletion steps
    }

    // Step 4: Set user status to deleted
    // Using supabaseAdmin since function is revoked from authenticated
    const { error: statusError } = await c.var.supabaseAdmin.rpc("set_user_status", {
      user_id: user.id,
      status: "deleted",
    });

    if (statusError) {
      const context14 = extractRequestContext(c);
      const logger14 = createLogger(context14);
      logger14.error("Failed to set user status", new Error(statusError.message), {
        user_id: user.id,
        status: "deleted",
      });
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
      const context15 = extractRequestContext(c);
      const logger15 = createLogger(context15);
      logger15.error("Failed to send notification email", emailError as Error, {
        user_id: user.id,
      });
      // Don't fail the request if email fails
    }

    return c.json({ success: true });
  } catch (error) {
    const context16 = extractRequestContext(c);
    const logger16 = createLogger(context16);
    logger16.error("Account deletion error", error as Error, {
      user_id: user.id,
    });
    return c.json({ message: "Failed to delete account" }, 500);
  }
});

export default account;
