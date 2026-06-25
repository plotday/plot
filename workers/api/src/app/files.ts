import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { rpcUser } from "../rpc";
import { twistFactory } from "../twist/factory";

// Cloudflare Workers extends the global CacheStorage with a `.default` cache.
declare const caches: CacheStorage & { default: Cache };

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

// Allowed preview width buckets (longest edge). Inputs are clamped to the
// smallest bucket >= requested width to maximize cache reuse / bound cost.
const PREVIEW_WIDTH_BUCKETS = [400, 800];

function parsePreviewWidth(raw: string | undefined): number | null {
  if (!raw) return null;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n <= 0 || String(n) !== raw) return null;
  return (
    PREVIEW_WIDTH_BUCKETS.find((b) => b >= n) ??
    PREVIEW_WIDTH_BUCKETS[PREVIEW_WIDTH_BUCKETS.length - 1]
  );
}

// Build the RFC 5987 Content-Disposition for an original (attachment) download.
function attachmentDisposition(fileName: string): string {
  const asciiFallback = fileName.replace(/[^\x20-\x7E]/g, "_");
  const encoded = encodeURIComponent(fileName).replace(
    /['()]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encoded}`;
}

// Download a file. Returns the R2 original unless ?w=<px> requests a resized
// inline preview, in which case a small WebP variant is produced via the
// Images binding (edge-cached), falling back to the original on any failure.
files.get("/files/:fileId", async (c) => {
  const user = c.var.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  const fileId = c.req.param("fileId");
  const width = parsePreviewWidth(c.req.query("w"));

  // Lazily fetch the R2 object (key includes the filename) so a preview cache
  // hit can serve without reading the original.
  let objectKey: string | null = null;
  let object: R2ObjectBody | null = null;
  let listed = false;
  const ensureObject = async (): Promise<R2ObjectBody | null> => {
    if (object || listed) return object;
    listed = true;
    const res = await c.env.FILES_BUCKET.list({ prefix: `files/${fileId}/` });
    if (!res.objects.length) return null;
    objectKey = res.objects[0].key;
    object = await c.env.FILES_BUCKET.get(objectKey);
    return object;
  };

  // Resolve the owning priority: DB (note this file is attached to) first, then
  // fall back to the R2 object's customMetadata for not-yet-attached uploads.
  const noteRow = await c.var.db
    .selectFrom("note")
    .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
    .select("thread_priority.priority_id")
    .where(sql<boolean>`note.actions @> ${JSON.stringify([{ fileId }])}::jsonb`)
    .where("thread_priority.user_id", "=", user.id)
    .executeTakeFirst();

  let priorityId = noteRow?.priority_id ?? null;
  if (!priorityId) {
    const obj = await ensureObject();
    if (!obj) {
      return c.json({ message: "File not found" }, 404);
    }
    priorityId = obj.customMetadata?.priorityId ?? null;
  }
  if (!priorityId) {
    return c.json({ message: "File metadata missing" }, 500);
  }

  // Access check ALWAYS runs before any cache read or transform.
  const hasAccess = await rpcUser(c.var.db, "has_priority_access", {
    user_id: user.id,
    priority_id: priorityId,
  });
  if (!hasAccess) {
    return c.json({ message: "Access denied" }, 403);
  }

  // --- Resized inline preview path ---
  if (width !== null) {
    const cache =
      typeof caches !== "undefined" ? caches.default : undefined;
    const cacheKey = c.req.url;

    if (cache) {
      const hit = await cache.match(cacheKey);
      if (hit) {
        const bytes = await hit.arrayBuffer();
        return new Response(bytes, {
          headers: {
            "Content-Type": hit.headers.get("Content-Type") ?? "image/webp",
            "Cache-Control": "private, max-age=31536000, immutable",
            "Content-Disposition": "inline",
          },
        });
      }
    }

    const obj = await ensureObject();
    if (!obj) {
      return c.json({ message: "File not found" }, 404);
    }

    const contentType =
      obj.httpMetadata?.contentType || "application/octet-stream";
    const bodyBytes = new Uint8Array(await obj.arrayBuffer()); // buffer once

    if (contentType.startsWith("image/")) {
      try {
        const result = await c.env.IMAGES.input(new Response(bodyBytes).body!)
          .transform({ width, height: width, fit: "scale-down" })
          .output({ format: "image/webp", quality: 80 });
        const variant = result.response();
        const bytes = await variant.arrayBuffer();
        const variantType = variant.headers.get("Content-Type") ?? "image/webp";

        // Edge-cache a public copy (only ever read back through this
        // auth-gated worker; the URL key is a random UUID).
        if (cache) {
          c.executionCtx.waitUntil(
            cache.put(
              cacheKey,
              new Response(bytes, {
                headers: {
                  "Content-Type": variantType,
                  "Cache-Control": "public, max-age=31536000, immutable",
                  "Content-Disposition": "inline",
                },
              }),
            ),
          );
        }

        return new Response(bytes, {
          headers: {
            "Content-Type": variantType,
            "Cache-Control": "private, max-age=31536000, immutable",
            "Content-Disposition": "inline",
          },
        });
      } catch (error) {
        c.var.tracker?.captureException(error, {
          context: "files:image-transform",
        });
        // fall through to serving the buffered original below
      }
    }

    // Non-image or transform failure: serve the buffered original.
    const fileName = (objectKey ?? "").split("/").pop() || "download";
    return new Response(bodyBytes, {
      headers: {
        "Content-Type": contentType,
        "Content-Disposition": attachmentDisposition(fileName),
      },
    });
  }

  // --- Full-size original path (no ?w) ---
  const obj = await ensureObject();
  if (!obj) {
    return c.json({ message: "File not found" }, 404);
  }
  const fileName = (objectKey ?? "").split("/").pop() || "download";
  const contentType =
    obj.httpMetadata?.contentType || "application/octet-stream";
  return new Response(obj.body, {
    headers: {
      "Content-Type": contentType,
      "Content-Disposition": attachmentDisposition(fileName),
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
