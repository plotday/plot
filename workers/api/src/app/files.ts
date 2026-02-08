import { Hono } from "hono";
import { createClient } from "@plotday/db";
import type { Bindings } from "../env";

const MAX_FILE_SIZE = 25 * 1024 * 1024; // 25MB

const files = new Hono<{ Bindings: Bindings }>();

// Upload a file
files.post("/files", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const formData = await c.req.formData();
  const file = formData.get("file");
  const priorityId = formData.get("priorityId");

  if (!file || !(file instanceof File)) {
    return c.json({ message: "Missing file" }, 400);
  }
  if (!priorityId || typeof priorityId !== "string") {
    return c.json({ message: "Missing priorityId" }, 400);
  }
  if (file.size > MAX_FILE_SIZE) {
    return c.json({ message: "File too large (max 25MB)" }, 400);
  }

  // Verify user has access to the priority (RLS enforces access)
  const { data: priority, error: priorityError } = await c.var.supabase
    .from("priority")
    .select("id")
    .eq("id", priorityId)
    .maybeSingle();

  if (priorityError || !priority) {
    return c.json({ message: "Priority not found or access denied" }, 403);
  }

  const fileId = crypto.randomUUID();
  const fileName = file.name;
  const mimeType = file.type || "application/octet-stream";

  await c.env.FILES_BUCKET.put(`files/${fileId}/${fileName}`, file.stream(), {
    customMetadata: {
      priorityId,
      uploadedBy: user.id,
    },
    httpMetadata: {
      contentType: mimeType,
    },
  });

  return c.json({
    fileId,
    fileName,
    fileSize: file.size,
    mimeType,
  });
});

// Download a file
files.get("/files/:fileId", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const fileId = c.req.param("fileId");

  // List objects with prefix to find the file (key includes filename)
  const listed = await c.env.FILES_BUCKET.list({ prefix: `files/${fileId}/` });
  if (!listed.objects.length) {
    return c.json({ message: "File not found" }, 404);
  }

  const objectKey = listed.objects[0].key;
  const object = await c.env.FILES_BUCKET.get(objectKey);
  if (!object) {
    return c.json({ message: "File not found" }, 404);
  }

  const priorityId = object.customMetadata?.priorityId;
  if (!priorityId) {
    return c.json({ message: "File metadata missing" }, 500);
  }

  // Verify user has access to the priority
  const supabase = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );
  const { data: hasAccess } = await supabase.rpc("user_has_priority_access", {
    user_id: user.id,
    target_priority_id: priorityId,
  });

  if (!hasAccess) {
    return c.json({ message: "Access denied" }, 403);
  }

  // Extract filename from the key (files/{fileId}/{fileName})
  const fileName = objectKey.split("/").pop() || "download";
  const contentType =
    object.httpMetadata?.contentType || "application/octet-stream";

  return new Response(object.body, {
    headers: {
      "Content-Type": contentType,
      "Content-Disposition": `attachment; filename="${fileName}"`,
    },
  });
});

export default files;
