import { Hono } from "hono";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { captureServerError } from "../utils/error-capture";
import {
  createStripeClient,
  createFreeTierBillingCycle,
} from "../stripe/utils";
import { notifySync } from "./sync/notify";

const organization = new Hono<{ Bindings: Bindings }>();

/**
 * Create a task thread in the user's personal root priority guiding them
 * to designate priorities for their new team.
 * Returns the priority ID the thread was created in, or null.
 */
export async function createTeamSetupTask(
  db: any,
  orgName: string,
  userId: string
): Promise<string | null> {
  // Find user's personal root priority
  const rootPu = await db
    .selectFrom("priority_user")
    .innerJoin("priority", "priority.id", "priority_user.priority_id")
    .select(["priority.id"])
    .where("priority_user.user_id", "=", userId)
    .where("priority_user.personal", "=", true)
    .where("priority_user.archived_at", "is", null)
    .executeTakeFirst();

  if (!rootPu) return null;

  // Create a thread (task)
  const thread = await db
    .insertInto("thread")
    .values({
      priority_id: rootPu.id,
      title: `Set up your ${orgName} team`,
      created_by: userId,
    })
    .returning("id")
    .executeTakeFirstOrThrow();

  // Add instructional note
  await db
    .insertInto("note")
    .values({
      thread_id: thread.id,
      content: `Your new Team plan applies to any priorities set to the **${orgName}** team. Edit existing priorities or add a new one to designate priorities for the team.`,
      created_by: userId,
      author_id: userId,
    })
    .execute();

  // Schedule as current to-do (undated per-user schedule with reason='task')
  await db
    .insertInto("schedule")
    .values({
      thread_id: thread.id,
      user_id: userId,
      order: Date.now(),
      reason: "task",
    })
    .execute();

  return rootPu.id;
}

/**
 * Give a user access to all priorities belonging to an organization
 * (for member add / invitation accept / auto-join).
 * Returns the list of priority IDs the user was given access to.
 */
export async function addUserToOrgPriorities(
  db: any,
  orgId: string | number,
  userId: string
): Promise<string[]> {
  const orgPriorities = await db
    .selectFrom("priority")
    .select("id")
    .where("organization_id", "=", orgId as any)
    .execute();

  for (const p of orgPriorities) {
    await db
      .insertInto("priority_user")
      .values({
        user_id: userId,
        priority_id: p.id,
        personal: false,
        archived_at: null,
      })
      .onConflict((oc: any) =>
        oc.columns(["user_id", "priority_id"]).doUpdateSet({ archived_at: null })
      )
      .execute();
  }

  return orgPriorities.map((p: any) => p.id as string);
}

/**
 * Helper: verify the current user is an admin of the given organization.
 * Returns the member row if admin, or null.
 */
async function requireAdmin(c: any, orgId: string) {
  const user = c.var.user;
  const member = await c.var.db
    .selectFrom("organization_member")
    .select(["id", "role"])
    .where("organization_id", "=", orgId as any)
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!member || member.role !== "admin") {
    return null;
  }
  return member;
}

// GET /organization - List user's organizations
organization.get("/organization", async (c) => {
  const user = c.var.user;

  const orgs = await c.var.db
    .selectFrom("organization_member as om")
    .innerJoin("organization as o", "o.id", "om.organization_id")
    .leftJoin(
      "organization_subscription as os",
      "os.organization_id",
      "om.organization_id"
    )
    .select([
      "o.id",
      "o.name",
      "om.role",
      "os.plan",
      "os.status",
    ])
    .where("om.user_id", "=", user.id)
    .execute();

  // Get member counts
  const orgIds = orgs.map((o) => o.id);
  let memberCounts: Record<string, number> = {};
  if (orgIds.length > 0) {
    const counts = await c.var.db
      .selectFrom("organization_member")
      .select(["organization_id"])
      .select((eb: any) => eb.fn.count("id").as("count"))
      .where("organization_id", "in", orgIds)
      .groupBy("organization_id")
      .execute();

    for (const row of counts as any[]) {
      memberCounts[String(row.organization_id)] = Number(row.count);
    }
  }

  return c.json(
    orgs.map((o) => ({
      id: String(o.id),
      name: o.name,
      role: o.role,
      plan: o.plan ?? "free",
      status: o.status ?? "active",
      memberCount: memberCounts[String(o.id)] ?? 0,
    }))
  );
});

// GET /organization/:id - Org details (admin only)
organization.get("/organization/:id", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const org = await c.var.db
    .selectFrom("organization")
    .select(["id", "name", "billing_email", "created_at"])
    .where("id", "=", orgId)
    .executeTakeFirst();

  if (!org) {
    return c.json({ error: "Not found" }, 404);
  }

  const [members, domains, subscription, invitations] = await Promise.all([
    c.var.db
      .selectFrom("organization_member as om")
      .innerJoin("user as u", "u.id", "om.user_id")
      .select([
        "om.user_id",
        "om.role",
        "om.created_at",
        "u.email",
        "u.name",
      ])
      .where("om.organization_id", "=", orgId)
      .execute(),
    c.var.db
      .selectFrom("domain")
      .select(["id", "name", "auto_join"])
      .where("organization_id", "=", orgId as any)
      .execute(),
    c.var.db
      .selectFrom("organization_subscription")
      .select(["plan", "status", "billing_cycle_start", "billing_cycle_end"])
      .where("organization_id", "=", orgId as any)
      .executeTakeFirst(),
    c.var.db
      .selectFrom("organization_invitation")
      .select(["id", "email", "role", "created_at"])
      .where("organization_id", "=", orgId as any)
      .execute(),
  ]);

  return c.json({
    id: String(org.id),
    name: org.name,
    billingEmail: org.billing_email,
    created_at: org.created_at,
    members: members.map((m) => ({
      userId: m.user_id,
      role: m.role,
      email: m.email,
      name: m.name,
      joinedAt: m.created_at,
    })),
    domains: domains.map((d) => ({
      id: String(d.id),
      name: d.name,
      autoJoin: d.auto_join,
    })),
    subscription: subscription
      ? {
          plan: subscription.plan,
          status: subscription.status,
          billingCycleStart: subscription.billing_cycle_start,
          billingCycleEnd: subscription.billing_cycle_end,
        }
      : null,
    invitations: invitations.map((inv) => ({
      id: String(inv.id),
      email: inv.email,
      role: inv.role,
      createdAt: inv.created_at,
    })),
  });
});

// POST /organization - Create org, caller becomes admin
organization.post("/organization", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ name: string }>();

  if (!body.name?.trim()) {
    return c.json({ error: "Name is required" }, 400);
  }

  try {
    const org = await c.var.db
      .insertInto("organization")
      .values({ name: body.name.trim() })
      .returning(["id", "name"])
      .executeTakeFirstOrThrow();

    await c.var.db
      .insertInto("organization_member")
      .values({
        organization_id: org.id,
        user_id: user.id,
        role: "admin",
      })
      .execute();

    // Create a task thread guiding the user to set up team priorities
    const priorityId = await createTeamSetupTask(c.var.db, org.name, user.id);
    if (priorityId) notifySync(c, priorityId);

    return c.json({ id: String(org.id), name: org.name }, 201);
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to create organization");
  }
});

// PATCH /organization/:id - Update org name and/or billing email
organization.patch("/organization/:id", async (c) => {
  const orgId = c.req.param("id");
  const user = c.var.user;

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ name?: string; billingEmail?: string | null }>();

  if (!body.name?.trim() && body.billingEmail === undefined) {
    return c.json({ error: "Name or billingEmail is required" }, 400);
  }

  try {
    const updates: Record<string, any> = {};

    if (body.name?.trim()) {
      updates.name = body.name.trim();
    }

    if (body.billingEmail !== undefined) {
      updates.billing_email = body.billingEmail?.trim() || null;
    }

    await c.var.db
      .updateTable("organization")
      .set(updates)
      .where("id", "=", orgId)
      .execute();

    // Sync billing email to Stripe Customer if it changed
    if (body.billingEmail !== undefined) {
      const orgSub = await c.var.db
        .selectFrom("organization_subscription")
        .select("stripe_customer_id")
        .where("organization_id", "=", orgId as any)
        .executeTakeFirst();

      if (orgSub?.stripe_customer_id) {
        const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
        await stripe.customers.update(orgSub.stripe_customer_id, {
          email: updates.billing_email || user.email,
        });
      }
    }

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to update organization");
  }
});

// POST /organization/:id/members - Add member by email
organization.post("/organization/:id/members", async (c) => {
  const orgId = c.req.param("id");
  const user = c.var.user;

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ email: string; role?: "admin" | "member" }>();

  if (!body.email?.trim()) {
    return c.json({ error: "Email is required" }, 400);
  }

  const email = body.email.trim().toLowerCase();
  const role = body.role ?? "member";

  // Check if user exists
  const existingUser = await c.var.db
    .selectFrom("user")
    .select("id")
    .where("email", "=", email)
    .executeTakeFirst();

  if (existingUser) {
    // Add directly as member
    try {
      await c.var.db
        .insertInto("organization_member")
        .values({
          organization_id: orgId as any,
          user_id: existingUser.id,
          role,
        })
        .onConflict((oc) =>
          oc
            .columns(["organization_id", "user_id"])
            .doUpdateSet({ role })
        )
        .execute();

      // Give member access to all org priorities
      const priorityIds = await addUserToOrgPriorities(c.var.db, orgId, existingUser.id);
      for (const pid of priorityIds) notifySync(c, pid);

      return c.json({ status: "added", userId: existingUser.id });
    } catch (err) {
      return captureServerError(c, err as Error, "Failed to add member");
    }
  } else {
    // Create invitation
    try {
      await c.var.db
        .insertInto("organization_invitation")
        .values({
          organization_id: orgId as any,
          email,
          role,
          invited_by: user.id,
        })
        .onConflict((oc) =>
          oc
            .columns(["organization_id", "email"])
            .doUpdateSet({ role, invited_by: user.id })
        )
        .execute();

      return c.json({ status: "invited", email });
    } catch (err) {
      return captureServerError(c, err as Error, "Failed to create invitation");
    }
  }
});

// DELETE /organization/:id/members/:userId - Remove member
organization.delete("/organization/:id/members/:userId", async (c) => {
  const orgId = c.req.param("id");
  const targetUserId = c.req.param("userId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  // Check if target is the last admin
  const targetMember = await c.var.db
    .selectFrom("organization_member")
    .select("role")
    .where("organization_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .executeTakeFirst();

  if (!targetMember) {
    return c.json({ error: "Member not found" }, 404);
  }

  if (targetMember.role === "admin") {
    const adminCount = await c.var.db
      .selectFrom("organization_member")
      .select((eb: any) => eb.fn.count("id").as("count"))
      .where("organization_id", "=", orgId as any)
      .where("role", "=", "admin")
      .executeTakeFirst();

    if (Number((adminCount as any)?.count) <= 1) {
      return c.json({ error: "Cannot remove the last admin" }, 400);
    }
  }

  // Archive user's access to all org priorities before removing membership
  const orgPriorities = await c.var.db
    .selectFrom("priority")
    .select("id")
    .where("organization_id", "=", orgId as any)
    .execute();

  await c.var.db
    .deleteFrom("organization_member")
    .where("organization_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .execute();

  for (const p of orgPriorities) {
    await c.var.db
      .updateTable("priority_user")
      .set({ archived_at: new Date().toISOString() })
      .where("user_id", "=", targetUserId)
      .where("priority_id", "=", p.id)
      .execute();
    notifySync(c, p.id);
  }

  return c.json({ success: true });
});

// PATCH /organization/:id/members/:userId - Change role
organization.patch("/organization/:id/members/:userId", async (c) => {
  const orgId = c.req.param("id");
  const targetUserId = c.req.param("userId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ role: "admin" | "member" }>();

  if (!body.role || !["admin", "member"].includes(body.role)) {
    return c.json({ error: "Valid role is required" }, 400);
  }

  // If demoting to member, check not last admin
  if (body.role === "member") {
    const targetMember = await c.var.db
      .selectFrom("organization_member")
      .select("role")
      .where("organization_id", "=", orgId as any)
      .where("user_id", "=", targetUserId)
      .executeTakeFirst();

    if (targetMember?.role === "admin") {
      const adminCount = await c.var.db
        .selectFrom("organization_member")
        .select((eb: any) => eb.fn.count("id").as("count"))
        .where("organization_id", "=", orgId as any)
        .where("role", "=", "admin")
        .executeTakeFirst();

      if (Number((adminCount as any)?.count) <= 1) {
        return c.json({ error: "Cannot demote the last admin" }, 400);
      }
    }
  }

  await c.var.db
    .updateTable("organization_member")
    .set({ role: body.role })
    .where("organization_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .execute();

  return c.json({ success: true });
});

// POST /organization/:id/domains - Link domain to org
organization.post("/organization/:id/domains", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ name: string; autoJoin?: boolean }>();

  if (!body.name?.trim()) {
    return c.json({ error: "Domain name is required" }, 400);
  }

  const domainName = body.name.trim().toLowerCase();

  try {
    // Check if domain exists
    const existing = await c.var.db
      .selectFrom("domain")
      .select(["id", "organization_id"])
      .where("name", "=", domainName)
      .executeTakeFirst();

    if (existing && existing.organization_id && String(existing.organization_id) !== orgId) {
      return c.json({ error: "Domain is already linked to another organization" }, 409);
    }

    if (existing) {
      await c.var.db
        .updateTable("domain")
        .set({
          organization_id: orgId as any,
          auto_join: body.autoJoin ?? false,
        })
        .where("id", "=", existing.id)
        .execute();

      return c.json({ id: String(existing.id), name: domainName, autoJoin: body.autoJoin ?? false });
    } else {
      const domain = await c.var.db
        .insertInto("domain")
        .values({
          name: domainName,
          organization_id: orgId as any,
          auto_join: body.autoJoin ?? false,
        })
        .returning(["id"])
        .executeTakeFirstOrThrow();

      return c.json({ id: String(domain.id), name: domainName, autoJoin: body.autoJoin ?? false }, 201);
    }
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to link domain");
  }
});

// DELETE /organization/:id/domains/:domainId - Unlink domain
organization.delete("/organization/:id/domains/:domainId", async (c) => {
  const orgId = c.req.param("id");
  const domainId = c.req.param("domainId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  await c.var.db
    .updateTable("domain")
    .set({ organization_id: null, auto_join: false })
    .where("id", "=", domainId)
    .where("organization_id", "=", orgId as any)
    .execute();

  return c.json({ success: true });
});

// PATCH /organization/:id/domains/:domainId - Toggle auto_join
organization.patch("/organization/:id/domains/:domainId", async (c) => {
  const orgId = c.req.param("id");
  const domainId = c.req.param("domainId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ autoJoin: boolean }>();

  if (typeof body.autoJoin !== "boolean") {
    return c.json({ error: "autoJoin must be a boolean" }, 400);
  }

  await c.var.db
    .updateTable("domain")
    .set({ auto_join: body.autoJoin })
    .where("id", "=", domainId)
    .where("organization_id", "=", orgId as any)
    .execute();

  return c.json({ success: true });
});

// POST /organization/:id/upgrade/checkout - Stripe Checkout for org
organization.post("/organization/:id/upgrade/checkout", async (c) => {
  const context = extractRequestContext(c);
  const logger = createLogger(context);
  const orgId = c.req.param("id");
  const user = c.var.user;

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const body = await c.req.json<{ priceLookupKey: string; quantity?: number }>();

  if (!body.priceLookupKey) {
    return c.json({ error: "priceLookupKey is required" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  // Get or create org Stripe customer
  let orgSub = await c.var.db
    .selectFrom("organization_subscription")
    .select("stripe_customer_id")
    .where("organization_id", "=", orgId as any)
    .executeTakeFirst();

  let stripeCustomerId = orgSub?.stripe_customer_id;

  if (!stripeCustomerId) {
    // Get org details for Stripe customer
    const org = await c.var.db
      .selectFrom("organization")
      .select(["name", "billing_email"])
      .where("id", "=", orgId)
      .executeTakeFirstOrThrow();

    const customer = await stripe.customers.create({
      name: org.name,
      email: org.billing_email || user.email,
      metadata: { organization_id: orgId },
    });
    stripeCustomerId = customer.id;

    // Create subscription record
    const { start, end } = createFreeTierBillingCycle();
    await c.var.db
      .insertInto("organization_subscription")
      .values({
        organization_id: orgId as any,
        stripe_customer_id: stripeCustomerId,
        plan: "free",
        status: "active",
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .onConflict((oc) =>
        oc.column("organization_id").doUpdateSet({
          stripe_customer_id: stripeCustomerId!,
        })
      )
      .execute();
  }

  // Look up price
  const prices = await stripe.prices.list({
    lookup_keys: [body.priceLookupKey],
    limit: 1,
  });

  if (prices.data.length === 0) {
    return c.json({ error: "Price not found" }, 400);
  }

  const session = await stripe.checkout.sessions.create({
    customer: stripeCustomerId,
    line_items: [
      {
        price: prices.data[0].id,
        quantity: body.quantity || 1,
      },
    ],
    mode: "subscription",
    success_url: `${siteRoot}/organization/${orgId}?success=true`,
    cancel_url: `${siteRoot}/organization/${orgId}?canceled=true`,
    billing_address_collection: "required",
    tax_id_collection: { enabled: true },
    customer_update: { address: "auto", name: "auto" },
    subscription_data: {
      metadata: {
        plan: "team",
        organization_id: orgId as any,
      },
    },
  });

  if (!session.url) {
    logger.error("Stripe checkout session created without URL", undefined, {
      session_id: session.id,
    });
    return c.json({ error: "Failed to create checkout session" }, 500);
  }

  return c.json({ url: session.url });
});

// POST /organization/:id/upgrade/portal - Stripe portal for org
organization.post("/organization/:id/upgrade/portal", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const orgSub = await c.var.db
    .selectFrom("organization_subscription")
    .select("stripe_customer_id")
    .where("organization_id", "=", orgId as any)
    .executeTakeFirst();

  if (!orgSub?.stripe_customer_id) {
    return c.json({ error: "No billing account found" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  const session = await stripe.billingPortal.sessions.create({
    customer: orgSub.stripe_customer_id,
    return_url: `${siteRoot}/organization/${orgId}`,
  });

  return c.json({ url: session.url });
});

export default organization;
