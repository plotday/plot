import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { extractRequestContext } from "../utils/log-context";
import { captureServerError } from "../utils/error-capture";
import {
  createStripeClient,
  createFreeTierBillingCycle,
} from "../stripe/utils";
import { notifySync } from "./sync/notify";

const team = new Hono<{ Bindings: Bindings }>();

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
  // Find user's root priority (depth-1 path)
  const rootPu = await db
    .selectFrom("priority")
    .select("id")
    .where("user_id", "=", userId)
    .where(sql<boolean>`nlevel(path) = 1`)
    .where("archived_at", "is", null)
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
 * Stub: In the per-user priority model, joining a team doesn't grant
 * access to specific priorities — each user owns their own tree.
 * Team membership is for billing/ownership only.
 */
export async function addUserToTeamPriorities(
  _db: any,
  _orgId: string | number,
  _userId: string
): Promise<string[]> {
  return [];
}

/**
 * Helper: verify the current user is an admin of the given team.
 * Returns the member row if admin, or null.
 */
async function requireAdmin(c: any, orgId: string) {
  const user = c.var.user;
  const member = await c.var.db
    .selectFrom("team_user")
    .select(["id", "role"])
    .where("team_id", "=", orgId as any)
    .where("user_id", "=", user.id)
    .executeTakeFirst();

  if (!member || member.role !== "admin") {
    return null;
  }
  return member;
}

// GET /team - List user's teams
team.get("/team", async (c) => {
  const user = c.var.user;

  const orgs = await c.var.db
    .selectFrom("team_user as om")
    .innerJoin("team as o", "o.id", "om.team_id")
    .leftJoin(
      "team_subscription as os",
      "os.team_id",
      "om.team_id"
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
      .selectFrom("team_user")
      .select(["team_id"])
      .select((eb: any) => eb.fn.count("id").as("count"))
      .where("team_id", "in", orgIds)
      .groupBy("team_id")
      .execute();

    for (const row of counts as any[]) {
      memberCounts[String(row.team_id)] = Number(row.count);
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

// GET /team/:id - Team details (admin only)
team.get("/team/:id", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const org = await c.var.db
    .selectFrom("team")
    .select(["id", "name", "billing_email", "created_at"])
    .where("id", "=", orgId)
    .executeTakeFirst();

  if (!org) {
    return c.json({ error: "Not found" }, 404);
  }

  const [members, domains, subscription, invitations] = await Promise.all([
    c.var.db
      .selectFrom("team_user as om")
      .innerJoin("user as u", "u.id", "om.user_id")
      .select([
        "om.user_id",
        "om.role",
        "om.created_at",
        "u.email",
        "u.name",
      ])
      .where("om.team_id", "=", orgId)
      .execute(),
    c.var.db
      .selectFrom("domain")
      .select(["id", "name", "auto_join"])
      .where("team_id", "=", orgId as any)
      .execute(),
    c.var.db
      .selectFrom("team_subscription")
      .select(["plan", "status", "billing_cycle_start", "billing_cycle_end"])
      .where("team_id", "=", orgId as any)
      .executeTakeFirst(),
    c.var.db
      .selectFrom("team_invitation")
      .select(["id", "email", "role", "created_at"])
      .where("team_id", "=", orgId as any)
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

// POST /team - Create team, caller becomes admin
team.post("/team", async (c) => {
  const user = c.var.user;
  const body = await c.req.json<{ name: string }>();

  if (!body.name?.trim()) {
    return c.json({ error: "Name is required" }, 400);
  }

  try {
    const org = await c.var.db
      .insertInto("team")
      .values({ name: body.name.trim() })
      .returning(["id", "name"])
      .executeTakeFirstOrThrow();

    await c.var.db
      .insertInto("team_user")
      .values({
        team_id: org.id,
        user_id: user.id,
        role: "admin",
      })
      .execute();

    // Create a task thread guiding the user to set up team priorities
    const priorityId = await createTeamSetupTask(c.var.db, org.name, user.id);
    if (priorityId) notifySync(c, priorityId);

    return c.json({ id: String(org.id), name: org.name }, 201);
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to create team");
  }
});

// PATCH /team/:id - Update team name and/or billing email
team.patch("/team/:id", async (c) => {
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
      .updateTable("team")
      .set(updates)
      .where("id", "=", orgId)
      .execute();

    // Sync billing email to Stripe Customer if it changed
    if (body.billingEmail !== undefined) {
      const orgSub = await c.var.db
        .selectFrom("team_subscription")
        .select("stripe_customer_id")
        .where("team_id", "=", orgId as any)
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
    return captureServerError(c, err as Error, "Failed to update team");
  }
});

// POST /team/:id/members - Add member by email
team.post("/team/:id/members", async (c) => {
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
        .insertInto("team_user")
        .values({
          team_id: orgId as any,
          user_id: existingUser.id,
          role,
        })
        .onConflict((oc) =>
          oc
            .columns(["team_id", "user_id"])
            .doUpdateSet({ role })
        )
        .execute();

      // Give member access to all org priorities
      const priorityIds = await addUserToTeamPriorities(c.var.db, orgId, existingUser.id);
      for (const pid of priorityIds) notifySync(c, pid);

      return c.json({ status: "added", userId: existingUser.id });
    } catch (err) {
      return captureServerError(c, err as Error, "Failed to add member");
    }
  } else {
    // Create invitation
    try {
      await c.var.db
        .insertInto("team_invitation")
        .values({
          team_id: orgId as any,
          email,
          role,
          invited_by: user.id,
        })
        .onConflict((oc) =>
          oc
            .columns(["team_id", "email"])
            .doUpdateSet({ role, invited_by: user.id })
        )
        .execute();

      return c.json({ status: "invited", email });
    } catch (err) {
      return captureServerError(c, err as Error, "Failed to create invitation");
    }
  }
});

// DELETE /team/:id/members/:userId - Remove member
team.delete("/team/:id/members/:userId", async (c) => {
  const orgId = c.req.param("id");
  const targetUserId = c.req.param("userId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  // Check if target is the last admin
  const targetMember = await c.var.db
    .selectFrom("team_user")
    .select("role")
    .where("team_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .executeTakeFirst();

  if (!targetMember) {
    return c.json({ error: "Member not found" }, 404);
  }

  if (targetMember.role === "admin") {
    const adminCount = await c.var.db
      .selectFrom("team_user")
      .select((eb: any) => eb.fn.count("id").as("count"))
      .where("team_id", "=", orgId as any)
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
    .where("team_id", "=", orgId as any)
    .execute();

  await c.var.db
    .deleteFrom("team_user")
    .where("team_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .execute();

  // In the per-user priority model, removing a team member doesn't
  // revoke access to priorities — each user owns their own tree.
  for (const p of orgPriorities) {
    notifySync(c, p.id);
  }

  return c.json({ success: true });
});

// PATCH /team/:id/members/:userId - Change role
team.patch("/team/:id/members/:userId", async (c) => {
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
      .selectFrom("team_user")
      .select("role")
      .where("team_id", "=", orgId as any)
      .where("user_id", "=", targetUserId)
      .executeTakeFirst();

    if (targetMember?.role === "admin") {
      const adminCount = await c.var.db
        .selectFrom("team_user")
        .select((eb: any) => eb.fn.count("id").as("count"))
        .where("team_id", "=", orgId as any)
        .where("role", "=", "admin")
        .executeTakeFirst();

      if (Number((adminCount as any)?.count) <= 1) {
        return c.json({ error: "Cannot demote the last admin" }, 400);
      }
    }
  }

  await c.var.db
    .updateTable("team_user")
    .set({ role: body.role })
    .where("team_id", "=", orgId as any)
    .where("user_id", "=", targetUserId)
    .execute();

  return c.json({ success: true });
});

// POST /team/:id/domains - Link domain to team
team.post("/team/:id/domains", async (c) => {
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
      .select(["id", "team_id"])
      .where("name", "=", domainName)
      .executeTakeFirst();

    if (existing && existing.team_id && String(existing.team_id) !== orgId) {
      return c.json({ error: "Domain is already linked to another team" }, 409);
    }

    if (existing) {
      await c.var.db
        .updateTable("domain")
        .set({
          team_id: orgId as any,
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
          team_id: orgId as any,
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

// DELETE /team/:id/domains/:domainId - Unlink domain
team.delete("/team/:id/domains/:domainId", async (c) => {
  const orgId = c.req.param("id");
  const domainId = c.req.param("domainId");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  await c.var.db
    .updateTable("domain")
    .set({ team_id: null, auto_join: false })
    .where("id", "=", domainId)
    .where("team_id", "=", orgId as any)
    .execute();

  return c.json({ success: true });
});

// PATCH /team/:id/domains/:domainId - Toggle auto_join
team.patch("/team/:id/domains/:domainId", async (c) => {
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
    .where("team_id", "=", orgId as any)
    .execute();

  return c.json({ success: true });
});

// POST /team/:id/upgrade/checkout - Stripe Checkout for team
team.post("/team/:id/upgrade/checkout", async (c) => {
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
    .selectFrom("team_subscription")
    .select("stripe_customer_id")
    .where("team_id", "=", orgId as any)
    .executeTakeFirst();

  let stripeCustomerId = orgSub?.stripe_customer_id;

  if (!stripeCustomerId) {
    // Get org details for Stripe customer
    const org = await c.var.db
      .selectFrom("team")
      .select(["name", "billing_email"])
      .where("id", "=", orgId)
      .executeTakeFirstOrThrow();

    const customer = await stripe.customers.create({
      name: org.name,
      email: org.billing_email || user.email,
      metadata: { team_id: orgId },
    });
    stripeCustomerId = customer.id;

    // Create subscription record
    const { start, end } = createFreeTierBillingCycle();
    await c.var.db
      .insertInto("team_subscription")
      .values({
        team_id: orgId as any,
        stripe_customer_id: stripeCustomerId,
        plan: "free",
        status: "active",
        billing_cycle_start: start.toISOString(),
        billing_cycle_end: end.toISOString(),
      })
      .onConflict((oc) =>
        oc.column("team_id").doUpdateSet({
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
    success_url: `${siteRoot}/team/${orgId}?success=true`,
    cancel_url: `${siteRoot}/team/${orgId}?canceled=true`,
    billing_address_collection: "required",
    tax_id_collection: { enabled: true },
    customer_update: { address: "auto", name: "auto" },
    subscription_data: {
      metadata: {
        plan: "team",
        team_id: orgId as any,
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

// POST /team/:id/upgrade/portal - Stripe portal for team
team.post("/team/:id/upgrade/portal", async (c) => {
  const orgId = c.req.param("id");

  if (!(await requireAdmin(c, orgId))) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const orgSub = await c.var.db
    .selectFrom("team_subscription")
    .select("stripe_customer_id")
    .where("team_id", "=", orgId as any)
    .executeTakeFirst();

  if (!orgSub?.stripe_customer_id) {
    return c.json({ error: "No billing account found" }, 400);
  }

  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const siteRoot = c.env.SITE_ROOT || "https://plot.day";

  const session = await stripe.billingPortal.sessions.create({
    customer: orgSub.stripe_customer_id,
    return_url: `${siteRoot}/team/${orgId}`,
  });

  return c.json({ url: session.url });
});

export default team;
