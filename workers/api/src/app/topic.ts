// /topic/* routes. apiVersion < 3 = legacy group-compat shim (old clients
// called groups "topics"); apiVersion >= 3 = the new topic ENTITY (channels).
// See docs/superpowers/plans/2026-06-05-groups-and-topics-api-sync.md (Plan 3).
import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";

const topic = new Hono<{ Bindings: Bindings }>();

/** Exported for unit testing. Returns true when the request carries apiVersion >= 3. */
export const isV3 = (c: { var: { apiVersion?: number } }) => (c.var.apiVersion ?? 0) >= 3;

// ---- legacy (apiVersion < 3) ----
const LegacyCreateSchema = z.object({
  name: z.string().min(1),
  type: z.enum(["public", "team", "private", "announce"]).default("private"),
  joinPolicy: z.enum(["member", "open", "admin"]).default("member"),
  teamId: z.number().int().optional(),
  memberContactIds: z.array(z.string().uuid()).default([]),
});
const LegacyMembersSchema = z.object({ contactIds: z.array(z.string().uuid()).min(1) });

// ---- new entity (apiVersion >= 3) ----
const CreateTopicSchema = z.object({
  name: z.string().min(1),
  announce: z.boolean().default(false),
  teamId: z.number().int().optional(),
  contactIds: z.array(z.string().uuid()).default([]),
  groupIds: z.array(z.string().uuid()).default([]),
});
const ContactsSchema = z.object({ contactIds: z.array(z.string().uuid()).min(1) });
const GroupsSchema = z.object({ groupIds: z.array(z.string().uuid()).min(1) });
const AdminSchema = z.object({ userId: z.string().uuid() });

function arrayLiteral(ids: string[]): any {
  return `{${ids.join(",")}}` as any;
}

topic.post("/topic", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const rawBody = await c.req.json();

  if (!isV3(c)) {
    const parsed = LegacyCreateSchema.safeParse(rawBody);
    if (!parsed.success) return handleValidationError(parsed.error);
    const { name, type, joinPolicy, teamId, memberContactIds } = parsed.data;
    try {
      const id = await c.var.db.transaction().execute((trx) =>
        rpc(trx, "create_group", {
          p_user_id: user.id,
          p_name: name,
          p_type: type,
          p_join_policy: joinPolicy,
          ...(teamId !== undefined ? { p_team_id: teamId } : {}),
          p_member_contact_ids: arrayLiteral(memberContactIds),
        }),
      );
      return c.json({ id });
    } catch (err) {
      const m = (err as Error).message;
      if (m.includes("not a member of this team")) return c.json({ message: "Not a member of this team" }, 403);
      return captureServerError(c, err as Error, "Failed to create topic", { user_id: user.id });
    }
  }

  const parsed = CreateTopicSchema.safeParse(rawBody);
  if (!parsed.success) return handleValidationError(parsed.error);
  const { name, announce, teamId, contactIds, groupIds } = parsed.data;
  try {
    const id = await c.var.db.transaction().execute((trx) =>
      rpc(trx, "create_topic", {
        p_user_id: user.id,
        p_name: name,
        p_announce: announce,
        ...(teamId !== undefined ? { p_team_id: teamId } : {}),
        p_contact_ids: arrayLiteral(contactIds),
        p_group_ids: arrayLiteral(groupIds),
      }),
    );
    return c.json({ id });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("not a member of this team")) return c.json({ message: "Not a member of this team" }, 403);
    return captureServerError(c, err as Error, "Failed to create topic", { user_id: user.id });
  }
});

// Legacy /topic/:id/members (apiVersion < 3 only — new entity uses /contacts + /groups)
async function legacyMembers(c: any, fn: "add_group_members" | "remove_group_members") {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  const parsed = LegacyMembersSchema.safeParse(await c.req.json());
  if (!parsed.success) return handleValidationError(parsed.error);
  try {
    await c.var.db.transaction().execute((trx: any) =>
      rpc(trx, fn, { p_user_id: user.id, p_group_id: id, p_contact_ids: arrayLiteral(parsed.data.contactIds) }),
    );
    return c.json({ success: true });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("auto-maintained") || m.includes("Only admins") || m.includes("Only members") || m.includes("Insufficient permission"))
      return c.json({ message: m }, 403);
    return captureServerError(c, err as Error, "Failed to modify topic members", { user_id: user.id, topic_id: id });
  }
}
topic.post("/topic/:id/members", (c) => legacyMembers(c, "add_group_members"));
topic.delete("/topic/:id/members", (c) => legacyMembers(c, "remove_group_members"));

// New entity membership: /contacts and /groups (apiVersion >= 3). For < 3 these
// paths are unused by old clients; we still route them to the topic RPCs.
async function topicContacts(c: any, fn: "add_topic_contacts" | "remove_topic_contacts") {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  const parsed = ContactsSchema.safeParse(await c.req.json());
  if (!parsed.success) return handleValidationError(parsed.error);
  try {
    await c.var.db.transaction().execute((trx: any) =>
      rpc(trx, fn, { p_user_id: user.id, p_topic_id: id, p_contact_ids: arrayLiteral(parsed.data.contactIds) }),
    );
    return c.json({ success: true });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("auto-maintained") || m.includes("Insufficient permission") || m.includes("not found"))
      return c.json({ message: m }, 403);
    return captureServerError(c, err as Error, "Failed to modify topic contacts", { user_id: user.id, topic_id: id });
  }
}
topic.post("/topic/:id/contacts", (c) => topicContacts(c, "add_topic_contacts"));
topic.delete("/topic/:id/contacts", (c) => topicContacts(c, "remove_topic_contacts"));

async function topicGroups(c: any, fn: "add_topic_groups" | "remove_topic_groups") {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  const parsed = GroupsSchema.safeParse(await c.req.json());
  if (!parsed.success) return handleValidationError(parsed.error);
  try {
    await c.var.db.transaction().execute((trx: any) =>
      rpc(trx, fn, { p_user_id: user.id, p_topic_id: id, p_group_ids: arrayLiteral(parsed.data.groupIds) }),
    );
    return c.json({ success: true });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("auto-maintained") || m.includes("Insufficient permission") || m.includes("not found"))
      return c.json({ message: m }, 403);
    return captureServerError(c, err as Error, "Failed to modify topic groups", { user_id: user.id, topic_id: id });
  }
}
topic.post("/topic/:id/groups", (c) => topicGroups(c, "add_topic_groups"));
topic.delete("/topic/:id/groups", (c) => topicGroups(c, "remove_topic_groups"));

// join / leave (apiVersion >= 3 entity)
topic.post("/topic/:id/join", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  try {
    await c.var.db.transaction().execute((trx) => rpc(trx, "join_topic", { p_user_id: user.id, p_topic_id: id }));
    return c.json({ success: true });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("not found")) return c.json({ message: m }, 404);
    return captureServerError(c, err as Error, "Failed to join topic", { user_id: user.id, topic_id: id });
  }
});
topic.post("/topic/:id/leave", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  try {
    await c.var.db.transaction().execute((trx) => rpc(trx, "leave_topic", { p_user_id: user.id, p_topic_id: id }));
    return c.json({ success: true });
  } catch (err) {
    const m = (err as Error).message;
    if (m.includes("not found")) return c.json({ message: m }, 404);
    return captureServerError(c, err as Error, "Failed to leave topic", { user_id: user.id, topic_id: id });
  }
});

// /topic/:id/admins — version-gated (topic_admin for >=3, group_admin for <3)
async function adminMutate(c: any, op: "add" | "remove") {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);
  const id = c.req.param("id");
  if (!z.string().uuid().safeParse(id).success) return c.json({ message: "Invalid topic ID" }, 400);
  const parsed = AdminSchema.safeParse(await c.req.json());
  if (!parsed.success) return handleValidationError(parsed.error);
  const table = isV3(c) ? "topic_admin" : "group_admin";
  const idCol = isV3(c) ? "topic_id" : "group_id";
  try {
    const callerIsAdmin = await c.var.db
      .selectFrom(table as any)
      .where(idCol as any, "=", id)
      .where("user_id", "=", user.id)
      .executeTakeFirst();
    if (!callerIsAdmin) return c.json({ message: `Only admins can ${op} admins` }, 403);

    if (op === "add") {
      await c.var.db.insertInto(table as any).values({ [idCol]: id, user_id: parsed.data.userId } as any)
        .onConflict((oc: any) => oc.doNothing()).execute();
    } else {
      await c.var.db.deleteFrom(table as any).where(idCol as any, "=", id).where("user_id", "=", parsed.data.userId).execute();
    }
    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, `Failed to ${op} topic admin`, { user_id: user.id, topic_id: id });
  }
}
topic.post("/topic/:id/admins", (c) => adminMutate(c, "add"));
topic.delete("/topic/:id/admins", (c) => adminMutate(c, "remove"));

export default topic;
