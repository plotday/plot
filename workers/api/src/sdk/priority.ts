import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";

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

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // Get all priorities the user has access to via user_priority view
  const { data: priorities, error } = await supabase
    .from("user_priority")
    .select("id, title, path")
    .eq("user_id", user.id)
    .is("archived_at", null)
    .order("path", { ascending: true });

  if (error) {
    const logger = createLogger();
    logger.error("Error fetching priorities", new Error(error.message), {
      user_id: user.id,
    });
    return new Response(`Error fetching priorities: ${error.message}`, {
      status: 500,
    });
  }

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

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  let parentPath: string;
  let createdBy: string;

  if (parentId) {
    // Verify user has access to the parent priority
    const { data: hasAccess } = await supabase.rpc("user_has_priority_access", {
      user_id: user.id,
      target_priority_id: parentId,
    });

    if (!hasAccess) {
      return new Response(
        "Forbidden: You do not have access to the specified parent priority",
        { status: 403 }
      );
    }

    // Get parent priority details
    const { data: parentPriority, error: parentError } = await supabase
      .from("priority")
      .select("path, created_by")
      .eq("id", parentId)
      .single();

    if (parentError || !parentPriority) {
      const logger = createLogger();
      logger.error("Error fetching parent priority", parentError ? new Error(parentError.message) : new Error("Unknown error"), {
        parent_id: parentId,
        user_id: user.id,
      });
      return new Response(
        `Error: Parent priority not found: ${parentError?.message}`,
        { status: 404 }
      );
    }

    parentPath = parentPriority.path as string;
    createdBy = parentPriority.created_by;
  } else {
    // No parent specified - get user's root priority
    const { data: rootPriorityUser, error: rootError } = await supabase
      .from("priority_user")
      .select("priority:priority_id(path)")
      .eq("user_id", user.id)
      .eq("personal", true)
      .single();

    if (rootError || !rootPriorityUser) {
      const logger = createLogger();
      logger.error("Error fetching root priority", rootError ? new Error(rootError.message) : new Error("Unknown error"), {
        user_id: user.id,
      });
      return new Response(
        `Error: User root priority not found: ${rootError?.message}`,
        { status: 500 }
      );
    }

    parentPath = (rootPriorityUser.priority as any).path as string;
    createdBy = user.id;
  }

  // Generate child path using database function
  const { data: childPath, error: pathError } = await supabase.rpc(
    "generate_path",
    {
      parent: parentPath,
    }
  );

  if (pathError || !childPath) {
    const logger = createLogger();
    logger.error("Error generating path", pathError ? new Error(pathError.message) : new Error("Unknown error"), {
      parent_path: parentPath,
      user_id: user.id,
    });
    return new Response(`Error: Path generation failed: ${pathError?.message}`, {
      status: 500,
    });
  }

  // Create the priority
  const { data: newPriority, error: createError } = await supabase
    .from("priority")
    .insert({
      created_by: createdBy,
      title: title,
      path: childPath,
      updated_by: 0,
    })
    .select()
    .single();

  if (createError || !newPriority) {
    const logger = createLogger();
    logger.error("Error creating priority", createError ? new Error(createError.message) : new Error("Unknown error"), {
      title,
      parent_path: parentPath,
      created_by: createdBy,
      user_id: user.id,
    });
    return new Response(
      `Error creating priority: ${createError?.message}`,
      { status: 500 }
    );
  }

  return c.json({
    id: newPriority.id,
    title: newPriority.title,
    created: newPriority.created_at,
  });
});

export default priority;
