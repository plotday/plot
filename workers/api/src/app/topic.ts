import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { captureServerError } from "../utils/error-capture";
import { handleValidationError } from "../utils/validation";

const topic = new Hono<{ Bindings: Bindings }>();

const CreateTopicSchema = z.object({
  name: z.string().min(1),
  type: z.enum(["public", "team", "private", "announce"]).default("private"),
  joinPolicy: z.enum(["member", "open", "admin"]).default("member"),
  teamId: z.number().int().optional(),
  memberContactIds: z.array(z.string().uuid()).default([]),
});

// POST /topic - Create a new topic
topic.post("/topic", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const rawBody = await c.req.json();
  const parseResult = CreateTopicSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  const { name, type, joinPolicy, teamId, memberContactIds } = parseResult.data;

  try {
    const topicId = await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "create_topic", {
        p_user_id: user.id,
        p_name: name,
        p_type: type,
        p_join_policy: joinPolicy,
        ...(teamId !== undefined ? { p_team_id: teamId } : {}),
        p_member_contact_ids: `{${memberContactIds.join(",")}}` as any,
      });
    });
    return c.json({ id: topicId });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("not a member of this team")) {
      return c.json({ message: "Not a member of this team" }, 403);
    }
    return captureServerError(c, err as Error, "Failed to create topic", {
      user_id: user.id,
    });
  }
});

const MembersSchema = z.object({
  contactIds: z.array(z.string().uuid()).min(1),
});

// POST /topic/:id/members - Add members
topic.post("/topic/:id/members", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const topicId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(topicId);
  if (!uuidResult.success) return c.json({ message: "Invalid topic ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = MembersSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "add_topic_members", {
        p_user_id: user.id,
        p_topic_id: topicId,
        p_contact_ids: `{${parseResult.data.contactIds.join(",")}}` as any,
      });
    });
    return c.json({ success: true });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("auto-maintained")) {
      return c.json({ message: "Cannot modify auto-maintained topic" }, 403);
    }
    if (errMsg.includes("Only admins") || errMsg.includes("Only members")) {
      return c.json({ message: errMsg }, 403);
    }
    return captureServerError(c, err as Error, "Failed to add topic members", {
      user_id: user.id, topic_id: topicId,
    });
  }
});

// DELETE /topic/:id/members - Remove members
topic.delete("/topic/:id/members", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const topicId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(topicId);
  if (!uuidResult.success) return c.json({ message: "Invalid topic ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = MembersSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    await c.var.db.transaction().execute(async (trx) => {
      return rpc(trx, "remove_topic_members", {
        p_user_id: user.id,
        p_topic_id: topicId,
        p_contact_ids: `{${parseResult.data.contactIds.join(",")}}` as any,
      });
    });
    return c.json({ success: true });
  } catch (err) {
    const errMsg = (err as Error).message;
    if (errMsg.includes("auto-maintained") || errMsg.includes("Insufficient permission")) {
      return c.json({ message: errMsg }, 403);
    }
    return captureServerError(c, err as Error, "Failed to remove topic members", {
      user_id: user.id, topic_id: topicId,
    });
  }
});

const AdminSchema = z.object({
  userId: z.string().uuid(),
});

// POST /topic/:id/admins - Add admin
topic.post("/topic/:id/admins", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const topicId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(topicId);
  if (!uuidResult.success) return c.json({ message: "Invalid topic ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = AdminSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    const isAdmin = await c.var.db
      .selectFrom("topic_admin")
      .where("topic_id", "=", topicId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!isAdmin) return c.json({ message: "Only admins can add admins" }, 403);

    await c.var.db
      .insertInto("topic_admin")
      .values({ topic_id: topicId, user_id: parseResult.data.userId })
      .onConflict((oc) => oc.doNothing())
      .execute();

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to add topic admin", {
      user_id: user.id, topic_id: topicId,
    });
  }
});

// DELETE /topic/:id/admins - Remove admin
topic.delete("/topic/:id/admins", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const topicId = c.req.param("id");
  const uuidResult = z.string().uuid().safeParse(topicId);
  if (!uuidResult.success) return c.json({ message: "Invalid topic ID" }, 400);

  const rawBody = await c.req.json();
  const parseResult = AdminSchema.safeParse(rawBody);
  if (!parseResult.success) return handleValidationError(parseResult.error);

  try {
    const isAdmin = await c.var.db
      .selectFrom("topic_admin")
      .where("topic_id", "=", topicId)
      .where("user_id", "=", user.id)
      .executeTakeFirst();

    if (!isAdmin) return c.json({ message: "Only admins can remove admins" }, 403);

    await c.var.db
      .deleteFrom("topic_admin")
      .where("topic_id", "=", topicId)
      .where("user_id", "=", parseResult.data.userId)
      .execute();

    return c.json({ success: true });
  } catch (err) {
    return captureServerError(c, err as Error, "Failed to remove topic admin", {
      user_id: user.id, topic_id: topicId,
    });
  }
});

export default topic;
