import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";

const group = new Hono<{ Bindings: Bindings }>();

const CreateGroupSchema = z.object({
  name: z.string().min(1),
  type: z.enum(["public", "team", "private", "announce"]).default("private"),
  joinPolicy: z.enum(["member", "open", "admin"]).default("member"),
  teamId: z.number().int().optional(),
  memberContactIds: z.array(z.string().uuid()).default([]),
});

group.post("/group", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const rawBody = await c.req.json();
  const parseResult = CreateGroupSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  const { name, type, joinPolicy, teamId, memberContactIds } = parseResult.data;

  try {
    const groupId = await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "create_group", {
        p_user_id: user.id,
        p_name: name,
        p_type: type,
        p_join_policy: joinPolicy,
        ...(teamId !== undefined ? { p_team_id: teamId } : {}),
        p_member_contact_ids: `{${memberContactIds.join(",")}}` as any,
      });
    });
    return c.json({ id: groupId });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("not a member of this team")) {
      return c.json({ message: "Not a member of this team" }, 403);
    }
    return captureServerError(c, err as Error, "Failed to create group", {
      user_id: user.id,
    });
  }
});

const MembersSchema = z.object({
  contactIds: z.array(z.string().uuid()).min(1),
});

group.post("/group/:id/members", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const groupId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(groupId);
  if (!uuidResult.success) return c.json({ message: "Invalid group ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = MembersSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "add_group_members", {
        p_user_id: user.id,
        p_group_id: groupId,
        p_contact_ids: `{${parseResult.data.contactIds.join(",")}}` as any,
      });
    });
    return c.json({ success: true });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("auto-maintained")) {
      return c.json({ message: "Cannot modify auto-maintained group" }, 403);
    }
    if (errMsg.includes("Only admins") || errMsg.includes("Only members")) {
      return c.json({ message: errMsg }, 403);
    }
    return captureServerError(c, err as Error, "Failed to add group members", {
      user_id: user.id, group_id: groupId,
    });
  }
});

group.delete("/group/:id/members", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const groupId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(groupId);
  if (!uuidResult.success) return c.json({ message: "Invalid group ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = MembersSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "remove_group_members", {
        p_user_id: user.id,
        p_group_id: groupId,
        p_contact_ids: `{${parseResult.data.contactIds.join(",")}}` as any,
      });
    });
    return c.json({ success: true });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("auto-maintained") || errMsg.includes("Insufficient permission")) {
      return c.json({ message: errMsg }, 403);
    }
    return captureServerError(c, err as Error, "Failed to remove group members", {
      user_id: user.id, group_id: groupId,
    });
  }
});

const AdminSchema = z.object({
  userId: z.string().uuid(),
});

group.post("/group/:id/admins", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const groupId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(groupId);
  if (!uuidResult.success) return c.json({ message: "Invalid group ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = AdminSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    const isAdmin = await c.var.db
      .selectFrom("group_admin")
      .where("group_id", "=", groupId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!isAdmin) return c.json({ message: "Only admins can add admins" }, 403);

    await c.var.db
      .insertInto("group_admin")
      .values({ group_id: groupId, user_id: parseResult.data.userId })
      .onConflict((oc) => oc.doNothing())
      .execute();

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to add group admin", {
      user_id: user.id, group_id: groupId,
    });
  }
});

group.delete("/group/:id/admins", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const groupId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(groupId);
  if (!uuidResult.success) return c.json({ message: "Invalid group ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = AdminSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    const isAdmin = await c.var.db
      .selectFrom("group_admin")
      .where("group_id", "=", groupId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!isAdmin) return c.json({ message: "Only admins can remove admins" }, 403);

    await c.var.db
      .deleteFrom("group_admin")
      .where("group_id", "=", groupId)
      .where("user_id", "=", parseResult.data.userId)
      .execute();

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to remove group admin", {
      user_id: user.id, group_id: groupId,
    });
  }
});

export default group;
