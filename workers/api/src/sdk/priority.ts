import { Hono } from "hono";
import { z } from "zod";

import { sql } from "kysely";

import { rpcUser } from "../rpc";
import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { generatePath } from "../utils/path";
import { handleValidationError } from "../utils/validation";
import { notifySync } from "../app/sync/notify";

const priority = new Hono<{ Bindings: Bindings }>();

const PriorityCreateSchema = z.object({
  title: z.string().min(1, "Title is required"),
  parentId: z.string().uuid().optional(),
});

// GET /priorities - List user's priorities (user token-based auth)
priority.get("/priorities", async (c) => {
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  const db = c.var.db;

  try {
    // Get all priorities the user has access to via user.priority view
    const priorities = await db
      .selectFrom("user.priority")
      .select(["id", "title", "path"])
      .where("user_id", "=", user.id)
      .where("archived_at", "is", null)
      .orderBy("path", "asc")
      .execute();

    // Process priorities to extract parent ID from path
    const result = priorities.map((p) => {
      const path = p.path as string;
      const pathParts = path.split(".");

      // Parent ID: find the priority with the parent path
      let parentId = null;
      if (pathParts.length > 1) {
        const parentPath = pathParts.slice(0, -1).join(".");
        const parent = priorities.find((pr) => pr.path === parentPath);
        if (parent) {
          parentId = parent.id;
        }
      }

      return {
        id: p.id,
        title: p.title,
        parentId,
      };
    });

    return c.json(result);
  } catch (error) {
    const logger = createLogger();
    logger.error(
      "Error fetching priorities",
      error instanceof Error ? error : new Error(String(error)),
      { user_id: user.id }
    );
    return new Response(
      `Error fetching priorities: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

// POST /priority - Create a new priority (user token-based auth)
priority.post("/priority", async (c) => {
  const userToken = c.var.userToken;
  const user = c.var.user;

  if (!userToken || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Parse and validate request body
  const rawBody = await c.req.json();
  const parseResult = PriorityCreateSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { title, parentId } = parseResult.data;

  const db = c.var.db;

  let parentPath: string;
  let createdBy: string;

  if (parentId) {
    // Verify user has access to the parent priority
    const hasAccess = await rpcUser(db, "has_priority_access", {
      user_id: user.id,
      priority_id: parentId,
    });

    if (!hasAccess) {
      return new Response(
        "Forbidden: You do not have access to the specified parent priority",
        { status: 403 }
      );
    }

    // Get parent priority details
    try {
      const parentPriority = await db
        .selectFrom("priority")
        .select(["path", "created_by"])
        .where("id", "=", parentId)
        .executeTakeFirstOrThrow();

      parentPath = parentPriority.path as string;
      createdBy = parentPriority.created_by;
    } catch (error) {
      const logger = createLogger();
      logger.error(
        "Error fetching parent priority",
        error instanceof Error ? error : new Error(String(error)),
        { parent_id: parentId, user_id: user.id }
      );
      return new Response(
        `Error: Parent priority not found: ${error instanceof Error ? error.message : "Unknown error"}`,
        { status: 404 }
      );
    }
  } else {
    // No parent specified - get user's root priority via a JOIN
    try {
      const rootPriority = await db
        .selectFrom("priority")
        .select("path")
        .where("user_id", "=", user.id)
        .where(sql<boolean>`nlevel(path) = 1`)
        .where("archived_at", "is", null)
        .executeTakeFirstOrThrow();

      parentPath = rootPriority.path as string;
      createdBy = user.id;
    } catch (error) {
      const logger = createLogger();
      logger.error(
        "Error fetching root priority",
        error instanceof Error ? error : new Error(String(error)),
        { user_id: user.id }
      );
      return new Response(
        `Error: User root priority not found: ${error instanceof Error ? error.message : "Unknown error"}`,
        { status: 500 }
      );
    }
  }

  // Generate child path in TypeScript (not via DB function — see utils/path.ts)
  const childPath = generatePath(parentPath);

  // Create the priority
  try {
    const newPriority = await db
      .insertInto("priority")
      .values({
        created_by: createdBy,
        user_id: createdBy,
        title: title,
        path: childPath,
        updated_by: 0,
        // This endpoint doesn't accept a role, so default the new focus to the
        // user's default role: it groups under a role in the sidebar and
        // satisfies the priority_role_or_fyi CHECK (role_id IS NOT NULL OR is_fyi).
        role_id: sql<string>`public.default_role_id(${createdBy}::uuid)`,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    notifySync(c, newPriority.id);

    return c.json({
      id: newPriority.id,
      title: newPriority.title,
      created: newPriority.created_at,
    });
  } catch (error) {
    const logger = createLogger();
    logger.error(
      "Error creating priority",
      error instanceof Error ? error : new Error(String(error)),
      {
        title,
        parent_path: parentPath,
        created_by: createdBy,
        user_id: user.id,
      }
    );
    return new Response(
      `Error creating priority: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

export default priority;
