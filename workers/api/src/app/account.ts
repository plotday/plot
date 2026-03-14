import { Hono } from "hono";
import { sql } from "kysely";
import { createClerkClient } from "@clerk/backend";

import { sendEmail } from "../email/send";
import type { Bindings } from "../env";
import type { AuthUser } from "../utils/auth";
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
import { captureServerError } from "../utils/error-capture";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { notifySync } from "./sync/notify";
import { addUserToOrgPriority } from "./organization";

const account = new Hono<{ Bindings: Bindings }>();


// POST /activate - Set up user account (idempotent)
// This is the only endpoint that can create new users. The auth middleware
// allows requests through even when the user doesn't exist in the DB yet,
// as long as the Clerk JWT is valid (clerkClaims will be set).
account.post("/activate", async (c) => {
  let user: AuthUser | undefined = c.var.user;

  // New user: JWT was valid but user doesn't exist in DB.
  // The auth middleware verified the JWT and set clerkClaims.
  if (!user) {
    const claims = c.var.clerkClaims;
    if (!claims) {
      return c.json({ message: "Unauthorized" }, 401);
    }

    let { clerkId, email, name } = claims;

    // Clerk JWTs may not include the email claim (e.g. OAuth "already signed in" path).
    // Fall back to fetching the user from Clerk's API.
    if (!email) {
      try {
        const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
        const clerkUser = await clerk.users.getUser(clerkId);
        email = clerkUser.emailAddresses.find(
          (e) => e.id === clerkUser.primaryEmailAddressId
        )?.emailAddress;
        if (!name) {
          name = [clerkUser.firstName, clerkUser.lastName].filter(Boolean).join(" ") || undefined;
        }
      } catch (err) {
        const context = extractRequestContext(c);
        const logger = createLogger(context);
        logger.error("Failed to fetch user from Clerk API", err as Error, { clerk_id: clerkId });
      }
    }

    if (!email) {
      return c.json({ message: "Email is required for activation" }, 400);
    }

    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Creating new user from Clerk JWT", { clerk_id: clerkId, email });

    // Upsert user: try by clerk_id first, fall back to linking by email
    // (handles existing users signing in with Clerk for the first time)
    try {
      // First, try to link by email if user already exists without this clerk_id
      const existingByEmail = await c.var.db
        .selectFrom("user")
        .select(["id", "email", "name", "clerk_id"])
        .where("email", "=", email)
        .executeTakeFirst();

      let row: { id: string; email: string; name: string | null };

      if (existingByEmail && existingByEmail.clerk_id !== clerkId) {
        // Existing user with different/no clerk_id — link them
        row = await c.var.db
          .updateTable("user")
          .set({ clerk_id: clerkId, name: name ?? existingByEmail.name })
          .where("id", "=", existingByEmail.id)
          .returning(["id", "email", "name"])
          .executeTakeFirstOrThrow();
      } else {
        // New user or same clerk_id — normal upsert
        row = await c.var.db
          .insertInto("user")
          .values({
            clerk_id: clerkId,
            email,
            name: name ?? null,
          })
          .onConflict((oc) =>
            oc.column("clerk_id").doUpdateSet({
              email,
              name: name ?? null,
            })
          )
          .returning(["id", "email", "name"])
          .executeTakeFirstOrThrow();
      }

      user = {
        id: row.id,
        clerkId,
        email: row.email,
        name: row.name,
      };
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to create user: ${(err as Error).message}`);
    }

    // Create primary contact for the user (if not exists)
    try {
      await c.var.db
        .insertInto("contact")
        .values({
          email,
          name: name ?? null,
          user_id: user.id,
          primary: true,
        })
        .onConflict((oc) => oc.column("email").doUpdateSet({
          name: name ?? null,
          user_id: user!.id,
          primary: true,
        }))
        .execute();
    } catch (err) {
      const logger2 = createLogger(extractRequestContext(c));
      logger2.error("Failed to create primary contact (non-blocking)", err as Error, {
        user_id: user.id,
      });
    }

    // Set external_id and contact_id on Clerk user so future JWTs include them
    // (done after contact creation so we can include contact_id in publicMetadata)
    try {
      const contact = await c.var.db
        .selectFrom("contact")
        .select("id")
        .where("user_id", "=", user.id)
        .where("primary", "=", true)
        .executeTakeFirst();

      const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
      await clerk.users.updateUser(clerkId, {
        externalId: user.id,
        publicMetadata: { contact_id: contact?.id ?? null },
      });
    } catch (err) {
      const logger2 = createLogger(extractRequestContext(c));
      logger2.error("Failed to set Clerk external_id/publicMetadata (non-blocking)", err as Error, {
        user_id: user.id,
        clerk_id: clerkId,
      });
    }
  }

  // Step 1: Check if root priority already exists
  let existingPriorityUser: { priority_id: string } | undefined;
  try {
    existingPriorityUser = await c.var.db
      .selectFrom("priority_user")
      .select("priority_id")
      .where("user_id", "=", user.id)
      .where("personal", "=", true)
      .executeTakeFirst();
  } catch (err) {
    return captureServerError(c, err as Error, `Failed to check for existing priority: ${(err as Error).message}`, {
      user_id: user.id,
    });
  }

  let priority: { id: string } | null = null;

  if (existingPriorityUser) {
    // Root priority already exists (e.g., from signup trigger or seed data)
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Root priority already exists, skipping creation", {
      user_id: user.id,
      priority_id: existingPriorityUser.priority_id,
    });
    priority = { id: existingPriorityUser.priority_id };
  } else {
    // Step 2: Generate path for root priority
    // rpc() unwraps scalar results, so we get the path string directly
    let rootPath: string;
    try {
      rootPath = await rpc(c.var.db, "generate_path", { parent: null }) as string;
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to generate path: ${(err as Error).message}`);
    }

    if (!rootPath) {
      return captureServerError(c, new Error("Unknown error"), "Failed to generate path: Unknown error");
    }

    // Step 3: Create root priority
    let newPriority: { id: string };
    try {
      newPriority = await c.var.db
        .insertInto("priority")
        .values({
          created_by: user.id,
          title: "Everything",
          path: rootPath,
          color: 0,
          updated_by: 0,
        })
        .returning("id")
        .executeTakeFirstOrThrow();
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to create root priority: ${(err as Error).message}`, {
        user_id: user.id,
      });
    }

    // Step 3.5: Mark the priority_user entry as root
    // The insert_priority_user trigger already created a priority_user entry
    try {
      await c.var.db
        .updateTable("priority_user")
        .set({ personal: true })
        .where("user_id", "=", user.id)
        .where("priority_id", "=", newPriority.id)
        .execute();
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to set personal flag: ${(err as Error).message}`, {
        user_id: user.id,
        priority_id: newPriority.id,
      });
    }

    // Step 3.6: Set default attention settings on root priority
    try {
      await sql`
        INSERT INTO priority_setting (user_id, priority_id, key, value)
        VALUES
          (${user.id}::uuid, ${newPriority.id}::uuid, 'attention_window',
           ${JSON.stringify([{ days: [1, 2, 3, 4, 5, 6, 7], start: "21:00", end: "07:00" }])}::jsonb),
          (${user.id}::uuid, ${newPriority.id}::uuid, 'see_within_requests',
           ${JSON.stringify({ value: 30, unit: "minutes" })}::jsonb),
          (${user.id}::uuid, ${newPriority.id}::uuid, 'see_within_updates',
           ${JSON.stringify({ value: 1, unit: "hours" })}::jsonb)
        ON CONFLICT (user_id, priority_id, key) DO NOTHING
      `.execute(c.var.db);
    } catch (err) {
      const logger = createLogger(extractRequestContext(c));
      logger.error("Failed to set default attention settings", err as Error, {
        user_id: user.id,
        priority_id: newPriority.id,
      });
    }

    priority = newPriority;
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
      email: user.email,
      name: user.name ?? undefined,
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

  // Step 6: Upsert user_subscription record with whatever Stripe data we have
  // Use upsert to make this idempotent in case of retries after failed activations
  try {
    await c.var.db
      .insertInto("user_subscription")
      .values({
        user_id: user.id,
        stripe_customer_id: stripeCustomerId,
        stripe_subscription_id: stripeSubscriptionId,
        plan: "free",
        status: "active",
        billing_cycle_start: billingStart.toISOString(),
        billing_cycle_end: billingEnd.toISOString(),
      })
      .onConflict((oc) =>
        oc.column("user_id").doUpdateSet({
          stripe_customer_id: stripeCustomerId,
          stripe_subscription_id: stripeSubscriptionId,
          plan: "free",
          status: "active",
          billing_cycle_start: billingStart.toISOString(),
          billing_cycle_end: billingEnd.toISOString(),
        })
      )
      .execute();
  } catch (err) {
    const context5 = extractRequestContext(c);
    const logger5 = createLogger(context5);
    logger5.error("Failed to create user_subscription", err as Error, {
      user_id: user.id,
    });
    return c.json(
      {
        message: `Failed to create subscription record: ${(err as Error).message}`,
      },
      400
    );
  }

  // Step 7: Create Plot priority if it doesn't exist
  // Get root priority path to search for @plot priority
  let rootPriorityData: { path: unknown } | undefined;
  try {
    rootPriorityData = await c.var.db
      .selectFrom("priority")
      .select("path")
      .where("id", "=", priority.id)
      .executeTakeFirstOrThrow();
  } catch (err) {
    return captureServerError(c, err as Error, `Failed to get root priority path: ${(err as Error).message}`, {
      user_id: user.id,
      priority_id: priority.id,
    });
  }

  const rootPath = rootPriorityData.path as string;
  const rootPathPart = rootPath.split(".")[0];

  // Check if @plot priority already exists
  let existingPlotPriority: { id: string } | undefined;
  try {
    existingPlotPriority = await c.var.db
      .selectFrom("priority")
      .select("id")
      .where("key", "=", "@plot")
      .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
      .executeTakeFirst();
  } catch (err) {
    return captureServerError(c, err as Error, `Failed to check for existing Plot priority: ${(err as Error).message}`, {
      user_id: user.id,
    });
  }

  let _plotPriorityId: string;

  if (existingPlotPriority) {
    // Plot priority already exists
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Plot priority already exists, skipping creation", {
      user_id: user.id,
      plot_priority_id: existingPlotPriority.id,
    });
    _plotPriorityId = existingPlotPriority.id;
  } else {
    // Create Plot priority
    // Generate path for Plot priority as child of root
    // rpc() unwraps scalar results, so we get the path string directly
    let plotPath: string;
    try {
      plotPath = await rpc(c.var.db, "generate_path", { parent: rootPath }) as string;
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to generate path for Plot priority: ${(err as Error).message}`);
    }

    if (!plotPath) {
      return captureServerError(c, new Error("Unknown error"), "Failed to generate path for Plot priority: Unknown error");
    }

    // Create Plot priority
    let newPlotPriority: { id: string };
    try {
      newPlotPriority = await c.var.db
        .insertInto("priority")
        .values({
          created_by: user.id,
          title: "Plot",
          path: plotPath,
          color: 7, // Resolution color (blue-gray)
          key: "@plot",
          updated_by: 0,
        })
        .returning("id")
        .executeTakeFirstOrThrow();
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to create Plot priority: ${(err as Error).message}`, {
        user_id: user.id,
      });
    }

    _plotPriorityId = newPlotPriority.id;
  }

  // Step 8: Install and activate Plot twist on root priority if not already installed
  // First, look up the Plot twist
  let plotTwist: { id: number; version: string } | undefined;
  try {
    const result = await c.var.db
      .selectFrom("twist")
      .select(["id", "version"])
      .where("name", "=", "Plot")
      .where("environment", "=", "public")
      .where("archived_at", "is", null)
      .orderBy("created_at", "asc")
      .limit(1)
      .executeTakeFirst();
    if (result) {
      plotTwist = { id: Number(result.id), version: result.version };
    }
  } catch (err) {
    return captureServerError(c, err as Error, `Failed to look up Plot twist: ${(err as Error).message}`, {
      user_id: user.id,
    });
  }

  if (!plotTwist) {
    const context6 = extractRequestContext(c);
    const logger6 = createLogger(context6);
    logger6.warn("Plot twist not found, skipping installation");
  } else {
    // Check if Plot twist is already installed on the root priority
    let existingPriorityTwist: { id: string } | undefined;
    try {
      existingPriorityTwist = await c.var.db
        .selectFrom("priority_twist")
        .select("id")
        .where("priority_id", "=", priority.id)
        .where("twist_id", "=", String(plotTwist.id))
        .where("archived_at", "is", null)
        .executeTakeFirst();
    } catch (err) {
      return captureServerError(c, err as Error, `Failed to check for existing Plot twist: ${(err as Error).message}`, {
        user_id: user.id,
        priority_id: priority.id,
      });
    }

    if (existingPriorityTwist) {
      // Plot twist already installed
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.info("Plot twist already installed on root priority, skipping installation", {
        user_id: user.id,
        priority_id: priority.id,
        priority_twist_id: existingPriorityTwist.id,
      });
    } else {
      // Install Plot twist
      try {
        await twistManagement.add(
          c.var.db,
          user.id,
          priority.id,
          plotTwist.id,
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
      } catch (error) {
        const context7 = extractRequestContext(c);
        const logger7 = createLogger(context7);
        logger7.error("Failed to add Plot twist", error as Error, {
          priority_id: priority.id,
          user_id: user.id,
        });
      }
    }
  }

  // Step 9: Set up Help & Feedback priority using database function
  try {
    const helpFeedbackResult = await rpc(c.var.db, "setup_help_feedback_priority", {
      p_user_name: user.name ?? undefined,
      p_user_id: user.id,
    });

    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.info("Successfully set up Help & Feedback priority", {
      user_id: user.id,
      result: helpFeedbackResult,
    });
  } catch (error) {
    // Fail open - log but don't block activation
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Exception setting up Help & Feedback priority", error as Error, {
      user_id: user.id,
    });
  }

  // Step 10: Process pending organization invitations
  try {
    const invitations = await c.var.db
      .selectFrom("organization_invitation")
      .select(["id", "organization_id", "role"])
      .where("email", "=", user.email.toLowerCase())
      .execute();

    for (const inv of invitations) {
      await c.var.db
        .insertInto("organization_member")
        .values({
          organization_id: inv.organization_id,
          user_id: user.id,
          role: inv.role,
        })
        .onConflict((oc) =>
          oc.columns(["organization_id", "user_id"]).doNothing()
        )
        .execute();

      await c.var.db
        .deleteFrom("organization_invitation")
        .where("id", "=", inv.id)
        .execute();

      // Give user access to org priority
      const _orgPriorityId = await addUserToOrgPriority(c.var.db, inv.organization_id, user.id);
      if (_orgPriorityId) notifySync(c, _orgPriorityId);
    }

    if (invitations.length > 0) {
      const context = extractRequestContext(c);
      const logger = createLogger(context);
      logger.info("Processed pending org invitations", {
        user_id: user.id,
        count: invitations.length,
      });
    }
  } catch (err) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to process org invitations (non-blocking)", err as Error, {
      user_id: user.id,
    });
  }

  // Step 11: Domain auto-join for organizations
  try {
    const emailDomain = user.email.split("@")[1]?.toLowerCase();
    if (emailDomain) {
      const domain = await c.var.db
        .selectFrom("domain")
        .select(["organization_id"])
        .where("name", "=", emailDomain)
        .where("auto_join", "=", true)
        .where("organization_id", "is not", null)
        .executeTakeFirst();

      if (domain?.organization_id) {
        await c.var.db
          .insertInto("organization_member")
          .values({
            organization_id: domain.organization_id,
            user_id: user.id,
            role: "member",
          })
          .onConflict((oc) =>
            oc.columns(["organization_id", "user_id"]).doNothing()
          )
          .execute();

        // Give user access to org priority
        const _domainOrgPriorityId = await addUserToOrgPriority(c.var.db, domain.organization_id, user.id);
        if (_domainOrgPriorityId) notifySync(c, _domainOrgPriorityId);

        const context = extractRequestContext(c);
        const logger = createLogger(context);
        logger.info("Auto-joined user to organization via domain", {
          user_id: user.id,
          domain: emailDomain,
          organization_id: String(domain.organization_id),
        });
      }
    }
  } catch (err) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to auto-join org via domain (non-blocking)", err as Error, {
      user_id: user.id,
    });
  }

  // Set up What's New priority (viewer role)
  try {
    await rpc(c.var.db, "setup_whats_new_priority", {
      p_user_id: user.id,
    });
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to setup What's New priority", error as Error, {
      user_id: user.id,
    });
  }

  notifySync(c, priority.id);

  // Look up the user's primary contact ID for the response
  let contactId: string | null = null;
  try {
    const contact = await c.var.db
      .selectFrom("contact")
      .select("id")
      .where("user_id", "=", user.id)
      .where("primary", "=", true)
      .executeTakeFirst();
    contactId = contact?.id ?? null;
  } catch (err) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to look up primary contact (non-blocking)", err as Error, {
      user_id: user.id,
    });
  }

  return c.json({
    userId: user.id,
    email: user.email,
    name: user.name,
    contactId,
  });
});

// DELETE /account - Delete user account
account.delete("/", async (c) => {
  const user = c.var.user;

  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  try {
    // Step 1: Get user subscription to find Stripe info
    let subscription: { stripe_subscription_id: string | null } | undefined;
    try {
      subscription = await c.var.db
        .selectFrom("user_subscription")
        .select("stripe_subscription_id")
        .where("user_id", "=", user.id)
        .executeTakeFirst();
    } catch (subError) {
      const context10 = extractRequestContext(c);
      const logger10 = createLogger(context10);
      logger10.error("Failed to fetch user subscription", subError as Error, {
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

    // Step 3: Ban the user in Clerk for 14 days
    const bannedUntil = new Date();
    bannedUntil.setDate(bannedUntil.getDate() + 14);

    try {
      const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
      await clerk.users.banUser(user.clerkId);
    } catch (banError) {
      const context13 = extractRequestContext(c);
      const logger13 = createLogger(context13);
      logger13.error("Failed to ban user in Clerk", banError as Error, {
        user_id: user.id,
        clerk_id: user.clerkId,
      });
      // Continue with other deletion steps
    }

    // Step 5: Send notification email to team@plot.day
    const emailResult = await sendEmail(
      {
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
      },
      c.env.RESEND_API_KEY
    );

    if (!emailResult.success) {
      const context15 = extractRequestContext(c);
      const logger15 = createLogger(context15);
      logger15.error(
        "Failed to send notification email",
        new Error(emailResult.error || "Unknown email error"),
        { user_id: user.id }
      );
      // Don't fail the request if email fails
    }

    return c.json({ success: true });
  } catch (error) {
    return captureServerError(c, error, "Failed to delete account", {
      user_id: user.id,
    });
  }
});

export default account;
