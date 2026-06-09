import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { rpcUser } from "../rpc";
import { twistFactory } from "../twist/factory";

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

  // Verify user has access to the priority
  const hasAccess = await rpcUser(c.var.db, "has_priority_access", {
    user_id: user.id,
    priority_id: priorityId,
  });

  if (!hasAccess) {
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

  // Look up priority from DB: note -> thread_priority for the current user
  const noteRow = await c.var.db
    .selectFrom("note")
    .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
    .select("thread_priority.priority_id")
    .where(sql<boolean>`note.actions @> ${JSON.stringify([{ fileId }])}::jsonb`)
    .where("thread_priority.user_id", "=", user.id)
    .executeTakeFirst();

  // Fall back to R2 metadata for files not yet attached to a note
  const priorityId = noteRow?.priority_id ?? object.customMetadata?.priorityId;
  if (!priorityId) {
    return c.json({ message: "File metadata missing" }, 500);
  }

  const hasAccess = await rpcUser(c.var.db, "has_priority_access", {
    user_id: user.id,
    priority_id: priorityId,
  });

  if (!hasAccess) {
    return c.json({ message: "Access denied" }, 403);
  }

  // Extract filename from the key (files/{fileId}/{fileName})
  const fileName = objectKey.split("/").pop() || "download";
  const contentType =
    object.httpMetadata?.contentType || "application/octet-stream";

  // ASCII fallback: replace non-ASCII chars with underscores
  const asciiFallback = fileName.replace(/[^\x20-\x7E]/g, "_");
  // RFC 5987 encoded filename for Unicode support
  const encodedFileName = encodeURIComponent(fileName).replace(
    /['()]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );

  return new Response(object.body, {
    headers: {
      "Content-Type": contentType,
      "Content-Disposition": `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encodedFileName}`,
    },
  });
});

// Resolve a fileRef action to its bytes via the owning connector
files.get("/files/ref/:noteId/:actionIndex", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const noteId = c.req.param("noteId");
  const rawIndex = c.req.param("actionIndex");

  // Validate actionIndex
  const actionIndex = parseInt(rawIndex, 10);
  if (!Number.isInteger(actionIndex) || actionIndex < 0 || String(actionIndex) !== rawIndex) {
    return c.json({ message: "Invalid actionIndex" }, 400);
  }

  // Load the note with thread_priority (user scoped), link, and twist_instance
  const noteRow = await c.var.db
    .selectFrom("note")
    .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
    .innerJoin("priority", (join) =>
      join
        .onRef("priority.id", "=", "thread_priority.priority_id")
        .on("priority.archived_at", "is", null)
    )
    .leftJoin("link", "link.id", "note.link_id")
    .select([
      "note.actions",
      "thread_priority.priority_id",
      "link.created_by as twistInstanceId",
    ])
    .where("note.id", "=", noteId)
    .where("thread_priority.user_id", "=", user.id)
    .executeTakeFirst();

  if (!noteRow) {
    return c.json({ message: "Note not found" }, 404);
  }

  // Verify priority access
  const hasAccess = await rpcUser(c.var.db, "has_priority_access", {
    user_id: user.id,
    priority_id: noteRow.priority_id as string,
  });
  if (!hasAccess) {
    return c.json({ message: "Access denied" }, 403);
  }

  // Validate the action
  const actions = noteRow.actions as Array<{ type: string; ref?: string; fileName?: string; mimeType?: string }> | null;
  const action = actions?.[actionIndex];
  if (!action) {
    return c.json({ message: "Action not found at index" }, 400);
  }
  if (action.type !== "fileRef") {
    return c.json({ message: "Action is not a fileRef" }, 400);
  }

  // Ensure a connector is associated
  const twistInstanceId = noteRow.twistInstanceId;
  if (!twistInstanceId) {
    return c.json({ message: "No connector associated with this fileRef" }, 410);
  }

  // Delegate to the connector's downloadAttachment method
  let result: unknown;
  try {
    const factory = twistFactory({
      env: c.env,
      ctx: c.executionCtx as ExecutionContext,
      db: c.var.db,
    });
    const wrapper = await factory({ twistInstanceId });
    result = await wrapper.runConnectorMethod("downloadAttachment", action.ref);
  } catch (error) {
    c.var.tracker?.captureException(error, { context: "files:ref" });
    return c.json({ message: "Source unavailable" }, 502);
  }

  const displayFileName = action.fileName ?? "download";

  // Map the result
  const res = result as { redirectUrl?: string; body?: ReadableStream | Uint8Array; mimeType?: string; fileName?: string };

  if (res.redirectUrl) {
    const finalFileName = res.fileName ?? displayFileName;
    const finalAscii = finalFileName.replace(/[^\x20-\x7E]/g, "_");
    const finalEncoded = encodeURIComponent(finalFileName).replace(
      /['()]/g,
      (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
    );
    return new Response(null, {
      status: 302,
      headers: {
        Location: res.redirectUrl,
        "Content-Type": action.mimeType ?? "application/octet-stream",
        "Content-Disposition": `attachment; filename="${finalAscii}"; filename*=UTF-8''${finalEncoded}`,
      },
    });
  }

  if (res.body !== undefined && res.mimeType) {
    const overrideName = res.fileName ?? displayFileName;
    const overrideAscii = overrideName.replace(/[^\x20-\x7E]/g, "_");
    const overrideEncoded = encodeURIComponent(overrideName).replace(
      /['()]/g,
      (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
    );
    // Cast to BodyInit: res.body is a ReadableStream or an ArrayBuffer-backed
    // Uint8Array at runtime, but TS's generic Uint8Array<ArrayBufferLike>
    // (which admits SharedArrayBuffer) isn't assignable to BodyInit directly.
    return new Response(res.body as BodyInit, {
      status: 200,
      headers: {
        "Content-Type": res.mimeType,
        "Content-Disposition": `attachment; filename="${overrideAscii}"; filename*=UTF-8''${overrideEncoded}`,
      },
    });
  }

  // Unexpected result shape
  c.var.tracker?.captureException(
    new Error(`downloadAttachment returned unexpected shape for twistInstance=${twistInstanceId}`),
    { context: "files:ref" },
  );
  return c.json({ message: "Source unavailable" }, 502);
});

export default files;
