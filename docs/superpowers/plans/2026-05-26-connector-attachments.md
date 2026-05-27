# Connector Attachment Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add end-to-end attachment support to Plot connectors — users attach files to notes that are delivered to source systems (Gmail, Slack, Linear, LinkedIn) as native attachments, and attachments arriving from those systems appear as first-class items on notes.

**Architecture:** Two action types on notes: existing `ActionType.file` (R2-backed) carries outbound; new `ActionType.fileRef` (source-backed, opaque ref) carries inbound. A new resolver endpoint `GET /files/ref/:noteId/:actionIndex` dispatches to the owning connector's new `downloadAttachment(ref)` method which returns either a redirect URL or a streamed body. A new `tools.files.read(fileId)` lets connectors read R2 bytes during outbound. No file is ever copied between the two paths.

**Tech Stack:** TypeScript (`public/twister/`, `workers/api/`), Hono routing, Cloudflare R2 (`FILES_BUCKET`), Kysely + Postgres, Flutter/Drift on the client. Connectors use the twist runtime in `workers/api/src/twist/`.

**Spec:** `docs/superpowers/specs/2026-05-26-connector-attachments-design.md`

---

## Task 1: Add `ActionType.fileRef` to twister SDK

**Files:**
- Modify: `public/twister/src/plot.ts:175-190` (enum), `public/twister/src/plot.ts:288-302` (union)

- [ ] **Step 1: Add `fileRef` to the `ActionType` enum**

In `public/twister/src/plot.ts` find the `ActionType` enum (around line 175) and add:

```typescript
export enum ActionType {
  /** External web links that open in browser */
  external = "external",
  /** Authentication flows for connecting services */
  auth = "auth",
  /** Callback actions that trigger twist methods when clicked */
  callback = "callback",
  /** Video conferencing links with provider-specific handling */
  conferencing = "conferencing",
  /** File attachment links stored in R2 */
  file = "file",
  /** Reference to an attachment hosted by a connector's source system */
  fileRef = "fileRef",
  /** Thread reference links for navigating to related threads */
  thread = "thread",
  /** Structured plan of operations for user approval */
  plan = "plan",
}
```

- [ ] **Step 2: Add the `fileRef` variant to the `Action` union**

In the same file, after the `ActionType.file` variant (around line 302) add:

```typescript
  | {
      /** Reference to an attachment hosted by a connector's source system */
      type: ActionType.fileRef;
      /** Opaque identifier interpreted only by the owning connector */
      ref: string;
      /** Display filename */
      fileName: string;
      /** File size in bytes if known */
      fileSize: number | null;
      /** MIME type */
      mimeType: string;
      /** Intrinsic width of the image in pixels (only for image files) */
      imageWidth?: number | null;
      /** Intrinsic height of the image in pixels (only for image files) */
      imageHeight?: number | null;
    }
```

- [ ] **Step 3: Type-check twister**

Run: `cd public/twister && pnpm lint`
Expected: clean (no TypeScript errors).

- [ ] **Step 4: Commit**

```bash
git add public/twister/src/plot.ts
git -C public commit -m "feat: add ActionType.fileRef for source-hosted attachments"
```

(Reminder: `public/` is a submodule. Commit inside the submodule, then in a later task bump the submodule pointer.)

---

## Task 2: Add `downloadAttachment` to the Connector base class

**Files:**
- Modify: `public/twister/src/connector.ts` (around line 406, near `onNoteCreated`)

- [ ] **Step 1: Add the abstract method**

Locate `onNoteCreated` in `Connector` class (around line 406). Immediately after it add:

```typescript
  /**
   * Resolve a `fileRef` action's bytes for download. Called when a user opens
   * an attachment in Plot. Return either a redirect URL (preferred for sources
   * that issue signed URLs, like Linear S3 or Slack permalink_public) or a
   * streamed body (required when bytes are only reachable through an
   * authenticated API call, like Gmail attachments.get).
   *
   * @param ref Opaque value the connector previously emitted on a fileRef action.
   * @returns Either `{ redirectUrl }` or `{ body, mimeType, fileName? }`.
   * @throws If the source is unavailable, the connection is broken, or `ref` is invalid.
   *
   * If not overridden, fileRef actions on this connector's notes will return 410 Gone.
   */
  async downloadAttachment(
    ref: string,
  ): Promise<
    | { redirectUrl: string }
    | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
  > {
    throw new Error(
      `downloadAttachment not implemented for ${this.constructor.name} (ref=${ref})`,
    );
  }
```

- [ ] **Step 2: Type-check**

Run: `cd public/twister && pnpm lint`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git -C public add twister/src/connector.ts
git -C public commit -m "feat: add Connector.downloadAttachment for fileRef resolution"
```

---

## Task 3: Add `Files` tool interface to twister SDK

**Files:**
- Create: `public/twister/src/tools/files.ts`
- Modify: `public/twister/src/tools/index.ts`
- Modify: `public/twister/package.json` (`exports` block)

- [ ] **Step 1: Create the tool interface**

Create `public/twister/src/tools/files.ts`:

```typescript
import { ITool } from "..";

/**
 * Built-in tool for reading files attached to notes in Plot.
 *
 * Files are uploaded by clients via POST /files which creates an
 * ActionType.file entry on a note. Connectors call read() during outbound
 * (e.g. onNoteCreated) to retrieve those bytes and send them to the source
 * system.
 *
 * For inbound attachments, connectors emit ActionType.fileRef actions and
 * implement Connector.downloadAttachment — no upload tool is needed because
 * inbound bytes never enter Plot's R2 storage.
 */
export abstract class Files extends ITool {
  /**
   * Read a file uploaded by a client and attached to a note in a priority
   * where this twist is installed.
   *
   * @param fileId The id from an ActionType.file action.
   * @returns Bytes plus original metadata.
   * @throws FileNotFoundError if the file is missing or out of scope.
   */
  abstract read(fileId: string): Promise<{
    data: Uint8Array;
    fileName: string;
    mimeType: string;
    fileSize: number;
  }>;
}

export class FileNotFoundError extends Error {
  constructor(fileId: string) {
    super(`File not found or out of scope: ${fileId}`);
    this.name = "FileNotFoundError";
  }
}
```

- [ ] **Step 2: Export from `tools/index.ts`**

In `public/twister/src/tools/index.ts` add:

```typescript
export * from "./files";
```

(Match the existing export style — open the file first; if it uses `export { Files } from "./files"`, mirror that.)

- [ ] **Step 3: Add `./tools/files` to package exports**

In `public/twister/package.json`, locate the `exports` block and add a new entry following the existing 3-field pattern:

```json
    "./tools/files": {
      "@plotday/connector": "./src/tools/files.ts",
      "types": "./dist/tools/files.d.ts",
      "default": "./dist/tools/files.js"
    },
```

Place it alphabetically between any neighboring `./tools/*` entries.

- [ ] **Step 4: Type-check**

Run: `cd public/twister && pnpm lint`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git -C public add twister/src/tools/files.ts twister/src/tools/index.ts twister/package.json
git -C public commit -m "feat: add Files tool interface for reading R2 attachments"
```

---

## Task 4: Add changeset and build twister

**Files:**
- Create: `public/.changeset/connector-attachments.md`

- [ ] **Step 1: Write the changeset**

Create `public/.changeset/connector-attachments.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `ActionType.fileRef` and `Connector.downloadAttachment` for source-hosted attachments, plus the `Files` tool with `read(fileId)` for outbound R2 reads. Connectors emit `fileRef` actions during inbound sync and serve their bytes on demand via `downloadAttachment`. Outbound continues to use `ActionType.file` backed by Plot's R2 storage.
```

- [ ] **Step 2: Validate the changeset**

Run: `cd public && pnpm validate-changesets`
Expected: validation passes.

- [ ] **Step 3: Build twister**

Run: `cd public/twister && pnpm build`
Expected: build succeeds, `dist/` is populated.

- [ ] **Step 4: Install in the parent repo so workspace link picks up new exports**

Run: `pnpm install`
Expected: install succeeds.

- [ ] **Step 5: Commit**

```bash
git -C public add .changeset/connector-attachments.md
git -C public commit -m "chore: changeset for attachment support"
```

---

## Task 5: Implement `Files` tool on the API side

**Files:**
- Create: `workers/api/src/twist/tools/files.ts`
- Modify: `workers/api/src/twist/entrypoint.ts` (register tool — see Task 6)

- [ ] **Step 1: Look up the existing `Tool` base class**

Open `workers/api/src/twist/tools/tool.ts` to confirm constructor signature and conventions. All concrete tools `extend Tool` and access the request context (`env`, `db`, `priorityId`, `twistInstanceId`) through it.

- [ ] **Step 2: Write the test**

Create `workers/api/src/twist/tools/files.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import { Files } from "./files";
import { setupTestEnv, seedNoteWithFile, putR2Object } from "../../../test/helpers";

describe("Files.read", () => {
  let ctx: Awaited<ReturnType<typeof setupTestEnv>>;

  beforeEach(async () => {
    ctx = await setupTestEnv();
  });

  it("returns bytes for a file attached to a note in the twist's priority", async () => {
    const fileId = crypto.randomUUID();
    await putR2Object(ctx, fileId, "hello.txt", "text/plain", new Uint8Array([0x68, 0x69]));
    await seedNoteWithFile(ctx, {
      priorityId: ctx.priorityId,
      fileId,
      fileName: "hello.txt",
      mimeType: "text/plain",
      fileSize: 2,
    });

    const tool = new Files(ctx.toolContext);
    const result = await tool.read(fileId);

    expect(result.fileName).toBe("hello.txt");
    expect(result.mimeType).toBe("text/plain");
    expect(result.fileSize).toBe(2);
    expect(Array.from(result.data)).toEqual([0x68, 0x69]);
  });

  it("throws FileNotFoundError when fileId is not on any note in scope", async () => {
    const tool = new Files(ctx.toolContext);
    await expect(tool.read("not-a-real-id")).rejects.toThrow("File not found");
  });

  it("throws FileNotFoundError when file is on a note in a different priority", async () => {
    const fileId = crypto.randomUUID();
    await putR2Object(ctx, fileId, "x.txt", "text/plain", new Uint8Array([1]));
    await seedNoteWithFile(ctx, {
      priorityId: ctx.otherPriorityId,
      fileId,
      fileName: "x.txt",
      mimeType: "text/plain",
      fileSize: 1,
    });

    const tool = new Files(ctx.toolContext);
    await expect(tool.read(fileId)).rejects.toThrow("File not found");
  });
});
```

If `setupTestEnv` / `seedNoteWithFile` / `putR2Object` helpers don't exist yet, add them to `workers/api/src/test/helpers.ts` following the patterns used by neighboring tool tests (`ai.test.ts`, `store.test.ts`). Each helper should be small and focused.

- [ ] **Step 3: Run the test, confirm it fails**

Run: `pnpm --filter @plotday/api test src/twist/tools/files.test.ts`
Expected: FAIL ("Files is not defined" or similar).

- [ ] **Step 4: Implement `Files`**

Create `workers/api/src/twist/tools/files.ts`:

```typescript
import { sql } from "kysely";
import { Tool } from "./tool";
import { FileNotFoundError } from "@plotday/twister/tools/files";

/**
 * Implementation of the Files tool. Reads R2 objects scoped to notes the
 * caller's twist instance can access.
 */
export class Files extends Tool {
  async read(fileId: string): Promise<{
    data: Uint8Array;
    fileName: string;
    mimeType: string;
    fileSize: number;
  }> {
    const { db, twistInstanceId } = this.ctx;

    // Confirm the fileId is referenced by a note in a priority where this
    // twist instance is installed. The query mirrors the access pattern used
    // by GET /files/:fileId.
    const row = await db
      .selectFrom("note")
      .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
      .innerJoin("priority_twist", "priority_twist.priority_id", "thread_priority.priority_id")
      .select(["note.id as noteId"])
      .where("priority_twist.id", "=", twistInstanceId)
      .where(sql<boolean>`note.actions @> ${JSON.stringify([{ fileId }])}::jsonb`)
      .limit(1)
      .executeTakeFirst();

    if (!row) {
      throw new FileNotFoundError(fileId);
    }

    const listed = await this.ctx.env.FILES_BUCKET.list({ prefix: `files/${fileId}/` });
    if (!listed.objects.length) {
      throw new FileNotFoundError(fileId);
    }

    const objectKey = listed.objects[0].key;
    const object = await this.ctx.env.FILES_BUCKET.get(objectKey);
    if (!object) {
      throw new FileNotFoundError(fileId);
    }

    const data = new Uint8Array(await object.arrayBuffer());
    const fileName = objectKey.split("/").pop() ?? "download";
    const mimeType = object.httpMetadata?.contentType ?? "application/octet-stream";

    return { data, fileName, mimeType, fileSize: data.byteLength };
  }
}
```

If `priority_twist.id` is not the column the runtime tracks per-instance, replace it with whatever field is on `this.ctx` (e.g. `priority_twist.twist_id`). The exploration phase showed `Tool` exposes the active twist context — match its actual property names.

- [ ] **Step 5: Run the test, confirm it passes**

Run: `pnpm --filter @plotday/api test src/twist/tools/files.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/twist/tools/files.ts workers/api/src/twist/tools/files.test.ts workers/api/src/test/helpers.ts
git commit -m "feat: implement Files.read tool for connector R2 reads"
```

---

## Task 6: Register `Files` tool in twist runtime

**Files:**
- Modify: `workers/api/src/twist/entrypoint.ts`

- [ ] **Step 1: Locate the tool registration**

Open `workers/api/src/twist/entrypoint.ts`. Find where existing tools (`AI`, `Plot`, `Integrations`, `Store`, `Network`, `Tasks`, `Callbacks`, `Imap`, `Smtp`, `Twists`) are listed/imported. This file is treated as a template literal — backticks must be escaped as `` \` `` (see AGENTS.md).

- [ ] **Step 2: Add the import and registration**

Add `import { Files } from "./tools/files";` alongside the other tool imports. In the registration block (where each tool is instantiated and assigned onto the twist context), add `files: new Files(toolCtx),` in the same shape used by `store: new Store(toolCtx)`.

Also update the recognized-fields list at the top of `dispatchToTool` (per the AGENTS.md note "When adding a new dispatch shape on a built-in tool, update BOTH `callCallback` and `dispatchToTool`") only if `Files` introduces a new dispatch shape. `Files.read` returns a plain object and is not a callback target, so no `dispatch()` changes are needed — leave both functions alone.

- [ ] **Step 3: Build the worker**

Run: `pnpm --filter @plotday/api lint && pnpm --filter @plotday/api build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/entrypoint.ts
git commit -m "feat: register Files tool in twist runtime"
```

---

## Task 7: Add `GET /files/ref/:noteId/:actionIndex` resolver endpoint

**Files:**
- Modify: `workers/api/src/app/files.ts`

- [ ] **Step 1: Write the test**

Create `workers/api/src/app/files.test.ts` (or append to existing if present):

```typescript
import { describe, it, expect, beforeEach } from "vitest";
import { app } from "../app";
import { setupTestEnv, seedNoteWithFileRef, seedConnector } from "../test/helpers";

describe("GET /files/ref/:noteId/:actionIndex", () => {
  let ctx: Awaited<ReturnType<typeof setupTestEnv>>;

  beforeEach(async () => {
    ctx = await setupTestEnv();
  });

  it("returns 302 when the connector returns { redirectUrl }", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "redirect-me", fileName: "a.pdf", mimeType: "application/pdf" });
    await seedConnector(ctx, note.linkId, {
      downloadAttachment: async () => ({ redirectUrl: "https://example.com/signed" }),
    });

    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);

    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe("https://example.com/signed");
    expect(res.headers.get("Content-Disposition")).toContain("a.pdf");
  });

  it("streams the body when the connector returns { body, mimeType }", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "stream-me", fileName: "b.txt", mimeType: "text/plain" });
    await seedConnector(ctx, note.linkId, {
      downloadAttachment: async () => ({
        body: new Uint8Array([0x68, 0x69]),
        mimeType: "text/plain",
        fileName: "b.txt",
      }),
    });

    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/plain");
    expect(await res.text()).toBe("hi");
  });

  it("returns 410 when the link has no live connector", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "orphan", fileName: "c.txt", mimeType: "text/plain", linkId: null });
    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);
    expect(res.status).toBe(410);
  });

  it("returns 502 when the connector throws", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "broken", fileName: "d.txt", mimeType: "text/plain" });
    await seedConnector(ctx, note.linkId, {
      downloadAttachment: async () => { throw new Error("source unavailable"); },
    });

    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);
    expect(res.status).toBe(502);
  });

  it("returns 400 when the action at index is not fileRef", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "x", fileName: "e.txt", mimeType: "text/plain" });
    // overwrite action 0 to be type=file
    await ctx.db.updateTable("note").set({ actions: JSON.stringify([{ type: "file", fileId: "x", fileName: "e.txt", fileSize: 1, mimeType: "text/plain" }]) }).where("id", "=", note.id).execute();

    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);
    expect(res.status).toBe(400);
  });

  it("returns 403 when the user lacks priority access", async () => {
    const note = await seedNoteWithFileRef(ctx, { ref: "z", fileName: "f.txt", mimeType: "text/plain", priorityId: ctx.otherPriorityId });
    const res = await app.request(`/files/ref/${note.id}/0`, { method: "GET" }, ctx.env);
    expect(res.status).toBe(403);
  });
});
```

Add `seedNoteWithFileRef` and `seedConnector` to `workers/api/src/test/helpers.ts`. `seedConnector` should produce a `priority_twist` row whose runtime stub replies with whatever `downloadAttachment` returns.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `pnpm --filter @plotday/api test src/app/files.test.ts`
Expected: FAIL (route returns 404).

- [ ] **Step 3: Implement the route**

In `workers/api/src/app/files.ts`, add after the existing `GET /files/:fileId` handler:

```typescript
files.get("/files/ref/:noteId/:actionIndex", async (c) => {
  const user = c.var.user;
  if (!user) return c.json({ message: "Unauthorized" }, 401);

  const noteId = c.req.param("noteId");
  const actionIndex = Number(c.req.param("actionIndex"));
  if (!Number.isInteger(actionIndex) || actionIndex < 0) {
    return c.json({ message: "Invalid actionIndex" }, 400);
  }

  const noteRow = await c.var.db
    .selectFrom("note")
    .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
    .leftJoin("link", "link.id", "note.link_id")
    .leftJoin("priority_twist", "priority_twist.id", "link.priority_twist_id")
    .select([
      "note.id as noteId",
      "note.actions",
      "thread_priority.priority_id",
      "priority_twist.id as twistInstanceId",
    ])
    .where("note.id", "=", noteId)
    .where("thread_priority.user_id", "=", user.id)
    .executeTakeFirst();

  if (!noteRow) return c.json({ message: "Note not found" }, 404);

  const hasAccess = await rpcUser(c.var.db, "has_priority_access", {
    user_id: user.id,
    priority_id: noteRow.priority_id,
  });
  if (!hasAccess) return c.json({ message: "Access denied" }, 403);

  const action = (noteRow.actions as Array<Record<string, unknown>> | null)?.[actionIndex];
  if (!action || action.type !== "fileRef" || typeof action.ref !== "string") {
    return c.json({ message: "Action is not a fileRef" }, 400);
  }

  if (!noteRow.twistInstanceId) {
    return c.json({ message: "Source no longer available" }, 410);
  }

  let result: { redirectUrl: string } | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string };
  try {
    result = await dispatchDownloadAttachment(c, noteRow.twistInstanceId, action.ref);
  } catch (error) {
    tracker?.captureException(error);
    return c.json({ message: "Source unavailable", error: String(error) }, 502);
  }

  const fileName = (action.fileName as string | undefined) ?? "download";
  const mimeType = (action.mimeType as string | undefined) ?? "application/octet-stream";
  const asciiFallback = fileName.replace(/[^\x20-\x7E]/g, "_");
  const encodedFileName = encodeURIComponent(fileName).replace(
    /['()]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  const disposition = `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encodedFileName}`;

  if ("redirectUrl" in result) {
    return new Response(null, {
      status: 302,
      headers: {
        Location: result.redirectUrl,
        "Content-Disposition": disposition,
        "Content-Type": mimeType,
      },
    });
  }

  const body = result.body instanceof Uint8Array ? result.body : result.body;
  return new Response(body, {
    headers: {
      "Content-Type": result.mimeType ?? mimeType,
      "Content-Disposition": disposition,
    },
  });
});
```

Add helper `dispatchDownloadAttachment` (in the same file or a sibling) that uses the twist runtime to call `downloadAttachment` on the named twist instance. The pattern mirrors how `Integrations.dispatch("onNoteCreated", ...)` is invoked elsewhere — see Task 8 for the runtime wiring.

- [ ] **Step 4: Run the test, confirm it passes**

Run: `pnpm --filter @plotday/api test src/app/files.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/files.ts workers/api/src/app/files.test.ts workers/api/src/test/helpers.ts
git commit -m "feat: add /files/ref resolver endpoint for fileRef downloads"
```

---

## Task 8: Wire `downloadAttachment` dispatch in twist runtime

**Files:**
- Modify: `workers/api/src/twist/entrypoint.ts`
- Modify: `workers/api/src/twist/dispatcher.ts` (or wherever `Integrations.dispatch` is implemented — confirm during the task)

- [ ] **Step 1: Find the existing connector callback dispatch**

Open `workers/api/src/twist/entrypoint.ts`. Locate where `onNoteCreated` is invoked — the exploration showed it's reached via `twistWrapper.dispatch("Integrations", { itemType: "channel_note", ... })`. Confirm whether the dispatch shape is `{ method, args }` or `{ sourceMethod, args }` and whether it routes through `callCallback` or `dispatchToTool`.

- [ ] **Step 2: Add a `downloadAttachment` dispatch path**

In the same dispatch table, add a case that, given `{ sourceMethod: "downloadAttachment", args: [ref] }`, looks up the active `Connector` instance on this twist context and calls `connector.downloadAttachment(ref)`, returning the result back to the caller.

If the existing dispatcher only handles fire-and-forget callbacks (no return value back to the HTTP request), add a new dispatch method `dispatchAndReturn` that awaits the result and serializes it. For `{ redirectUrl }` the value is plain JSON. For `{ body, mimeType }` the body must travel as a `ReadableStream` (use `Response.body` if necessary, or transfer `Uint8Array` directly inside the DO/runtime — confirm based on the runtime's transport).

- [ ] **Step 3: Wire the resolver's helper to the dispatcher**

Implement `dispatchDownloadAttachment` referenced in Task 7 to call the new runtime method:

```typescript
async function dispatchDownloadAttachment(
  c: Context,
  twistInstanceId: string,
  ref: string,
): Promise<
  | { redirectUrl: string }
  | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
> {
  const wrapper = await getTwistWrapper(c, twistInstanceId);
  return wrapper.dispatchAndReturn("downloadAttachment", [ref]);
}
```

- [ ] **Step 4: Re-run the resolver tests**

Run: `pnpm --filter @plotday/api test src/app/files.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/entrypoint.ts workers/api/src/twist/dispatcher.ts workers/api/src/app/files.ts
git commit -m "feat: dispatch downloadAttachment through twist runtime"
```

---

## Task 9: Flutter — model fileRef actions

**Files:**
- Modify: `apps/plot/lib/store/user_action.dart`

- [ ] **Step 1: Locate the existing `FileUserAction` class**

Open `apps/plot/lib/store/user_action.dart` (lines 172–199 per exploration). Note the field set on `FileUserAction`: `fileId`, `fileName`, `fileSize`, `mimeType`, image dimensions.

- [ ] **Step 2: Add `FileRefUserAction`**

Add a sibling class:

```dart
class FileRefUserAction extends UserAction {
  final String ref;
  final String fileName;
  final int? fileSize;
  final String mimeType;
  final int? imageWidth;
  final int? imageHeight;

  FileRefUserAction({
    required this.ref,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    this.imageWidth,
    this.imageHeight,
  });

  @override
  UserActionType get type => UserActionType.fileRef;

  bool get isImage => mimeType.startsWith('image/');

  factory FileRefUserAction.fromJson(Map<String, dynamic> json) =>
      FileRefUserAction(
        ref: json['ref'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mimeType'] as String,
        imageWidth: (json['imageWidth'] as num?)?.toInt(),
        imageHeight: (json['imageHeight'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'fileRef',
        'ref': ref,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        if (imageWidth != null) 'imageWidth': imageWidth,
        if (imageHeight != null) 'imageHeight': imageHeight,
      };
}
```

- [ ] **Step 3: Add `fileRef` to `UserActionType` enum**

In the same file (or wherever `UserActionType` lives), add the `fileRef` variant.

- [ ] **Step 4: Update the factory that decodes `UserAction` from JSON**

Find the `UserAction.fromJson` switch and add the `fileRef` case routing to `FileRefUserAction.fromJson`.

- [ ] **Step 5: Verify analyzer is happy**

Run: `cd apps/plot && flutter analyze lib/store/user_action.dart`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/user_action.dart
git commit -m "feat(flutter): model FileRefUserAction"
```

---

## Task 10: Flutter — render fileRef actions in note view

**Files:**
- Modify: `apps/plot/lib/widget/note_action.dart`
- Modify: `apps/plot/lib/widget/file_link_button.dart` (likely; confirm path during task)

- [ ] **Step 1: Inspect existing `note_action.dart`**

Open `apps/plot/lib/widget/note_action.dart`. The exploration showed lines 94–104 dispatch `UserActionType.file` to `FileImageWidget` / `FileLinkButton`.

- [ ] **Step 2: Add a `fileRef` case**

Add immediately after the `UserActionType.file` case:

```dart
case UserActionType.fileRef:
  final fileRef = link as FileRefUserAction;
  if (fileRef.isImage) {
    return FileRefImageWidget(link: fileRef, noteId: noteId, actionIndex: actionIndex);
  }
  return FileRefLinkButton(
    link: fileRef,
    noteId: noteId,
    actionIndex: actionIndex,
    variant: variant,
    style: style,
    textStyle: textStyle,
  );
```

`noteId` and `actionIndex` must reach the rendering function. If they're not already in scope, thread them through from the caller (note builder/widget that holds the `Note` object and iterates `actions`).

- [ ] **Step 3: Create `FileRefLinkButton` and `FileRefImageWidget`**

In a new file `apps/plot/lib/widget/file_ref_widgets.dart`, write thin wrappers that mirror `FileLinkButton` / `FileImageWidget` but compute the download URL as `/files/ref/$noteId/$actionIndex`. Reuse the API base URL from the existing HTTP client.

On 410 response: render a disabled tile with "Source no longer available". On 502: render a tile with a retry button. On 200/302: hand off to the system file viewer (existing pattern in `FileLinkButton`).

- [ ] **Step 4: Verify analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/note_action.dart lib/widget/file_ref_widgets.dart`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/note_action.dart apps/plot/lib/widget/file_ref_widgets.dart
git commit -m "feat(flutter): render fileRef actions in note view"
```

---

## Task 11: Flutter — composer file-attach affordance

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart` and/or `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Search for any existing affordance**

Run: `grep -rn "ActionType.file\|FileUserAction\|POST /files\|FilePicker\|pickFiles" apps/plot/lib/`

If a file-attach UI already exists for `ActionType.file`, **skip the rest of this task** and commit nothing — the existing path produces the right output for outbound. Document in the commit log that you verified no UI work was needed.

If not, continue.

- [ ] **Step 2: Add paperclip button + file picker**

In the note composer toolbar, add an icon button that opens a system file picker via `package:file_picker`:

```dart
IconButton(
  icon: const Icon(LucideIcons.paperclip),
  tooltip: 'Attach file',
  onPressed: _onAttachFilePressed,
),
```

- [ ] **Step 3: Implement upload**

```dart
Future<void> _onAttachFilePressed() async {
  final result = await FilePicker.platform.pickFiles(withData: true);
  if (result == null) return;
  final file = result.files.single;
  if (file.bytes == null) return;
  if (file.size > 25 * 1024 * 1024) {
    showSnackBar(context, 'Max file size is 25 MB');
    return;
  }

  final uploaded = await api.uploadFile(
    bytes: file.bytes!,
    fileName: file.name,
    priorityId: widget.priorityId,
  );

  setState(() {
    _pendingActions.add(FileUserAction(
      fileId: uploaded.fileId,
      fileName: uploaded.fileName,
      fileSize: uploaded.fileSize,
      mimeType: uploaded.mimeType,
    ));
  });
}
```

Add `api.uploadFile` in `apps/plot/lib/api/api.dart` if missing — POST multipart `/files`, return `{fileId, fileName, fileSize, mimeType}`.

- [ ] **Step 4: Render pending action chips in composer**

Below the editor field, render `_pendingActions` as removable chips. On send, attach them to the new note via the existing note-create call.

- [ ] **Step 5: Manual smoke**

Launch via the `run-app` skill, attach a small file, send. Verify the note appears with a `file` action in the local DB:

```bash
psql "$DATABASE_URL" -c "SELECT id, actions FROM note ORDER BY created_at DESC LIMIT 1;"
```

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/lib/widget/note_editor.dart apps/plot/lib/api/api.dart
git commit -m "feat(flutter): add file-attach affordance to note composer"
```

---

## Task 12: Gmail — outbound attachments in `onNoteCreated`

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts:1251-1300` (existing `onNoteCreated`)
- Modify: `public/connectors/gmail/src/build-reply-message.ts` (or wherever `buildReplyMessage` lives)

- [ ] **Step 1: Read the existing reply builder**

Open the file that defines `buildReplyMessage`. It currently produces a plain-text or HTML MIME message. We need to wrap it in `multipart/mixed` when attachments are present.

- [ ] **Step 2: Extend `buildReplyMessage` to take attachments**

Add an `attachments` parameter:

```typescript
type ReplyAttachment = {
  fileName: string;
  mimeType: string;
  data: Uint8Array;
};

export function buildReplyMessage(opts: {
  to: string;
  cc?: string;
  subject: string;
  inReplyTo: string;
  references: string;
  bodyText: string;
  attachments: ReplyAttachment[];
}): string {
  if (opts.attachments.length === 0) {
    return buildSimpleMessage(opts);  // existing path
  }
  const boundary = `----=_Part_${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const headers = [
    `To: ${opts.to}`,
    opts.cc ? `Cc: ${opts.cc}` : null,
    `Subject: ${opts.subject}`,
    `In-Reply-To: ${opts.inReplyTo}`,
    `References: ${opts.references}`,
    `MIME-Version: 1.0`,
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
  ].filter(Boolean).join("\r\n");

  const textPart = [
    `--${boundary}`,
    `Content-Type: text/plain; charset=UTF-8`,
    `Content-Transfer-Encoding: 7bit`,
    ``,
    opts.bodyText,
  ].join("\r\n");

  const attachmentParts = opts.attachments.map((a) => [
    `--${boundary}`,
    `Content-Type: ${a.mimeType}; name="${a.fileName}"`,
    `Content-Disposition: attachment; filename="${a.fileName}"`,
    `Content-Transfer-Encoding: base64`,
    ``,
    chunkBase64(btoa(String.fromCharCode(...a.data))),
  ].join("\r\n"));

  return [headers, ``, textPart, ...attachmentParts, `--${boundary}--`].join("\r\n");
}

function chunkBase64(s: string): string {
  return s.match(/.{1,76}/g)?.join("\r\n") ?? s;
}
```

(For attachments approaching 25 MB, `String.fromCharCode(...a.data)` will blow the stack — use a chunked encoder instead. A safe pattern: iterate over the buffer in 32 KB slices and concatenate base64 chunks.)

- [ ] **Step 3: Pluck file actions in `onNoteCreated`**

In `gmail.ts` `onNoteCreated`, after the existing thread-context lookup:

```typescript
const fileActions = (note.actions ?? []).filter(
  (a): a is Extract<Action, { type: ActionType.file }> => a.type === ActionType.file,
);

const attachments: ReplyAttachment[] = [];
for (const action of fileActions) {
  try {
    const f = await this.tools.files.read(action.fileId);
    attachments.push({ fileName: f.fileName, mimeType: f.mimeType, data: f.data });
  } catch (e) {
    console.error("Failed to read attachment", action.fileId, e);
  }
}

const raw = buildReplyMessage({ ...opts, attachments });
// existing send call follows
```

- [ ] **Step 4: Build and lint**

Run: `cd public/connectors/gmail && pnpm lint && pnpm build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git -C public add connectors/gmail/src/gmail.ts connectors/gmail/src/build-reply-message.ts
git -C public commit -m "feat(gmail): send file actions as MIME attachments in onNoteCreated"
```

---

## Task 13: Gmail — emit `fileRef` actions during inbound sync

**Files:**
- Modify: `public/connectors/gmail/src/gmail-api.ts` (where messages are mapped to Plot notes — confirm during task)

- [ ] **Step 1: Locate the inbound message mapper**

The exploration pointed to `syncGmailChannel()` in `gmail-api.ts`. Find where each Gmail message is converted to a Plot note (the spot that fills `content`, `actions`, etc.).

- [ ] **Step 2: Parse Gmail attachment parts**

Gmail's message parts model: walk `payload.parts` recursively. Any part with `filename` non-empty and a `body.attachmentId` is an attachment. Add:

```typescript
type GmailPart = { filename?: string; mimeType?: string; body?: { attachmentId?: string; size?: number }; parts?: GmailPart[] };

function collectAttachments(part: GmailPart | undefined): Array<{ partId: string; fileName: string; fileSize: number | null; mimeType: string }> {
  if (!part) return [];
  const here = part.filename && part.body?.attachmentId
    ? [{
        partId: part.body.attachmentId!,
        fileName: part.filename,
        fileSize: part.body?.size ?? null,
        mimeType: part.mimeType ?? "application/octet-stream",
      }]
    : [];
  const children = (part.parts ?? []).flatMap(collectAttachments);
  return [...here, ...children];
}
```

- [ ] **Step 3: Emit `fileRef` actions**

In the message-to-note mapper, replace any current attachment handling with:

```typescript
const attachments = collectAttachments(message.payload);
const actions: Action[] = attachments.map((a) => ({
  type: ActionType.fileRef,
  ref: `${message.id}:${a.partId}`,
  fileName: a.fileName,
  fileSize: a.fileSize,
  mimeType: a.mimeType,
}));
```

and pass `actions` to `tools.plot.createNote(...)` / the inline `Note` shape returned from sync.

- [ ] **Step 4: Build**

Run: `cd public/connectors/gmail && pnpm build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git -C public add connectors/gmail/src/gmail-api.ts
git -C public commit -m "feat(gmail): emit fileRef actions for inbound attachments"
```

---

## Task 14: Gmail — implement `downloadAttachment`

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts`

- [ ] **Step 1: Add the override**

In the `Gmail` class:

```typescript
async downloadAttachment(ref: string): Promise<{ body: Uint8Array; mimeType: string; fileName?: string }> {
  const [messageId, partId] = ref.split(":");
  if (!messageId || !partId) throw new Error(`Invalid Gmail attachment ref: ${ref}`);

  // The connector instance has multiple channels; we don't know which one.
  // The note's link_id resolves to the priority_twist, but ref doesn't carry
  // the channel. Look it up: any channel on this connector whose API can fetch
  // the message will do.
  const channelId = await this.findChannelForMessage(messageId);
  if (!channelId) throw new Error(`No Gmail channel found for message ${messageId}`);

  const api = await this.getApi(channelId);
  const att = await api.users.messages.attachments.get({
    userId: "me",
    messageId,
    id: partId,
  });

  // Gmail returns base64url-encoded data
  const b64 = (att.data.data ?? "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64.padEnd(Math.ceil(b64.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  return {
    body: bytes,
    mimeType: "application/octet-stream",  // mime comes from the action, not the API
  };
}

private async findChannelForMessage(messageId: string): Promise<string | null> {
  // Iterate channels; first one whose API returns the message wins.
  // Cache result via this.tools.store for subsequent calls.
  const cached = await this.tools.store.get<string>(`msg-channel:${messageId}`);
  if (cached) return cached;

  for (const channelId of await this.listChannelIds()) {
    try {
      const api = await this.getApi(channelId);
      await api.users.messages.get({ userId: "me", id: messageId, format: "minimal" });
      await this.tools.store.set(`msg-channel:${messageId}`, channelId);
      return channelId;
    } catch {
      // try next
    }
  }
  return null;
}
```

If `listChannelIds` doesn't exist as a method, look up channels via the connector's existing channel registry (the exploration referenced `meta.channelId` on threads — adapt to the actual API).

- [ ] **Step 2: Build**

Run: `cd public/connectors/gmail && pnpm build`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git -C public add connectors/gmail/src/gmail.ts
git -C public commit -m "feat(gmail): implement downloadAttachment via attachments.get"
```

---

## Task 15: Slack — outbound attachments in `onNoteCreated`

**Files:**
- Modify: `public/connectors/slack/src/slack.ts:1038-1063` (existing `onNoteCreated`)
- Modify: Slack API client wrapper (likely `public/connectors/slack/src/slack-api.ts` — confirm)

- [ ] **Step 1: Add Slack file upload helpers**

In the Slack API wrapper add:

```typescript
async getUploadURLExternal(filename: string, length: number): Promise<{ upload_url: string; file_id: string }> {
  const res = await this.call("files.getUploadURLExternal", { filename, length });
  return { upload_url: res.upload_url, file_id: res.file_id };
}

async completeUploadExternal(fileId: string, title: string, channelId: string, threadTs?: string): Promise<void> {
  await this.call("files.completeUploadExternal", {
    files: JSON.stringify([{ id: fileId, title }]),
    channel_id: channelId,
    thread_ts: threadTs,
  });
}
```

- [ ] **Step 2: Update `onNoteCreated`**

Modify the existing handler so that for each `ActionType.file` action it:

1. Calls `files.getUploadURLExternal` for the file.
2. PUTs the bytes from `this.tools.files.read(fileId)` to the returned `upload_url`.
3. Calls `files.completeUploadExternal` with the channel and (optional) thread_ts.

Text body still goes through `api.postMessage` as today; if there are attachments, post text first, then complete upload with `thread_ts` matching the new message's `ts`.

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const meta = thread.meta ?? {};
  const channelId = meta.channelId as string;
  const threadTs = meta.threadTs as string | undefined;
  const tokenChannelId = (meta.tokenChannelId as string | undefined) ?? channelId;
  if (!channelId) { console.error("No channelId"); return; }

  const api = await this.getApi(tokenChannelId);

  const body = note.content ?? "";
  const postResult = await api.postMessage(channelId, body, threadTs);
  if (!postResult?.ts) return;

  const fileActions = (note.actions ?? []).filter(a => a.type === "file");
  for (const action of fileActions) {
    try {
      const file = await this.tools.files.read(action.fileId);
      const { upload_url, file_id } = await api.getUploadURLExternal(file.fileName, file.fileSize);
      await fetch(upload_url, { method: "PUT", body: file.data });
      await api.completeUploadExternal(file_id, file.fileName, channelId, postResult.ts);
    } catch (e) {
      console.error("Failed to send Slack attachment", action.fileId, e);
    }
  }

  return {
    key: postResult.ts,
    externalContent: formatSlackText(postResult.text ?? body),
  };
}
```

- [ ] **Step 3: Build**

Run: `cd public/connectors/slack && pnpm build`

- [ ] **Step 4: Commit**

```bash
git -C public add connectors/slack/src/slack.ts connectors/slack/src/slack-api.ts
git -C public commit -m "feat(slack): upload file actions via files.completeUploadExternal"
```

---

## Task 16: Slack — emit `fileRef` actions during inbound sync + implement `downloadAttachment`

**Files:**
- Modify: `public/connectors/slack/src/slack.ts` (webhook/event handler)
- Modify: Same file for `downloadAttachment`

- [ ] **Step 1: Parse `files` array from Slack messages**

Wherever a Slack message event is converted to a Plot note, read `event.files` and emit:

```typescript
const actions: Action[] = (event.files ?? []).map((f: SlackFile) => ({
  type: ActionType.fileRef,
  ref: f.id,
  fileName: f.name ?? "file",
  fileSize: f.size ?? null,
  mimeType: f.mimetype ?? "application/octet-stream",
  imageWidth: f.original_w ?? null,
  imageHeight: f.original_h ?? null,
}));
```

- [ ] **Step 2: Implement `downloadAttachment`**

```typescript
async downloadAttachment(ref: string): Promise<{ redirectUrl: string } | { body: ReadableStream; mimeType: string; fileName?: string }> {
  // ref is the Slack file id. Look up file info to get url_private and permalink_public.
  const channelId = await this.findChannelForFile(ref);  // see Gmail pattern, cached via tools.store
  if (!channelId) throw new Error(`No Slack channel for file ${ref}`);
  const api = await this.getApi(channelId);

  const info = await api.call("files.info", { file: ref });
  const f = info.file;
  if (f.permalink_public) {
    return { redirectUrl: f.permalink_public };
  }

  const res = await fetch(f.url_private, {
    headers: { Authorization: `Bearer ${await api.getToken()}` },
  });
  if (!res.ok || !res.body) throw new Error(`Slack file fetch failed: ${res.status}`);

  return {
    body: res.body,
    mimeType: f.mimetype ?? "application/octet-stream",
    fileName: f.name,
  };
}
```

- [ ] **Step 3: Build**

Run: `cd public/connectors/slack && pnpm build`

- [ ] **Step 4: Commit**

```bash
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "feat(slack): inbound fileRef actions + downloadAttachment"
```

---

## Task 17: Linear — outbound attachments in `onNoteCreated`

**Files:**
- Modify: `public/connectors/linear/src/linear.ts:769-796` (existing `onNoteCreated`)
- Modify: Linear API client (search for `fileUpload` GraphQL usage; may not yet exist)

- [ ] **Step 1: Add `fileUpload` mutation**

In Linear's API client add:

```typescript
async fileUpload(input: { filename: string; size: number; contentType: string }): Promise<{ uploadUrl: string; assetUrl: string; headers: Record<string,string> }> {
  const data = await this.gql(`
    mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
      fileUpload(filename: $filename, contentType: $contentType, size: $size) {
        success
        uploadFile { uploadUrl assetUrl headers { key value } }
      }
    }
  `, input);
  const uf = data.fileUpload.uploadFile;
  return {
    uploadUrl: uf.uploadUrl,
    assetUrl: uf.assetUrl,
    headers: Object.fromEntries(uf.headers.map((h: any) => [h.key, h.value])),
  };
}
```

- [ ] **Step 2: Update `onNoteCreated` / `addIssueComment`**

In `addIssueComment` (around line 805):

```typescript
async addIssueComment(meta: Record<string, unknown>, content: string, fileActions: FileAction[] = []): Promise<NoteWriteBackResult | void> {
  // ... existing client setup
  const uploadedMarkdown: string[] = [];
  for (const action of fileActions) {
    try {
      const file = await this.tools.files.read(action.fileId);
      const upload = await client.fileUpload({ filename: file.fileName, size: file.fileSize, contentType: file.mimeType });
      await fetch(upload.uploadUrl, { method: "PUT", body: file.data, headers: upload.headers });
      uploadedMarkdown.push(`![${file.fileName}](${upload.assetUrl})`);
    } catch (e) {
      console.error("Linear file upload failed", action.fileId, e);
    }
  }

  const body = [content, ...uploadedMarkdown].filter(Boolean).join("\n\n");
  // ... existing comment-create call with body
}
```

In `onNoteCreated`:

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const fileActions = (note.actions ?? []).filter((a): a is FileAction => a.type === "file");
  return this.addIssueComment(thread.meta ?? {}, note.content ?? "", fileActions);
}
```

- [ ] **Step 3: Build and commit**

```bash
cd public/connectors/linear && pnpm build
git -C public add connectors/linear/src/linear.ts
git -C public commit -m "feat(linear): upload file actions via fileUpload mutation"
```

---

## Task 18: Linear — emit `fileRef` actions during inbound + implement `downloadAttachment`

**Files:**
- Modify: `public/connectors/linear/src/linear.ts` (issue/comment sync)

- [ ] **Step 1: Parse Linear `attachments`**

When syncing issues and comments, fetch their attachments (the GraphQL `attachments` connection on each issue) and emit:

```typescript
const actions: Action[] = (issue.attachments?.nodes ?? []).map((a: LinearAttachment) => ({
  type: ActionType.fileRef,
  ref: a.id,
  fileName: a.title ?? "attachment",
  fileSize: null,  // Linear's attachment doesn't expose size on this connection
  mimeType: a.metadata?.mimeType ?? "application/octet-stream",
}));
```

- [ ] **Step 2: Implement `downloadAttachment`**

```typescript
async downloadAttachment(ref: string): Promise<{ redirectUrl: string }> {
  // Need a project context to get the right client. Cache the ref→projectId mapping.
  const projectId = await this.tools.store.get<string>(`att-project:${ref}`);
  if (!projectId) throw new Error(`Unknown Linear attachment: ${ref}`);
  const client = await this.getClient(projectId);

  const att = await client.attachment(ref);
  if (!att.url) throw new Error(`Attachment ${ref} has no url`);

  return { redirectUrl: att.url };
}
```

Populate `att-project:${ref}` in the inbound sync (Step 1 above) so this lookup succeeds.

- [ ] **Step 3: Build and commit**

```bash
cd public/connectors/linear && pnpm build
git -C public add connectors/linear/src/linear.ts
git -C public commit -m "feat(linear): inbound fileRef actions + downloadAttachment"
```

---

## Task 19: LinkedIn — outbound attachments in `onNoteCreated`

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (private; not under `public/`)

- [ ] **Step 1: Confirm Unipile attachment upload surface**

Open `libs/unipile/src/` and find the `sendMessage` shape. If it takes an `attachments` array, the Unipile SDK already encapsulates multipart upload. Otherwise add a thin wrapper that uses Unipile's `POST /messages` endpoint with multipart body.

- [ ] **Step 2: Add `onNoteCreated`**

LinkedIn currently has no `onNoteCreated` override per the exploration. Add one mirroring Slack/Linear shape:

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const meta = thread.meta ?? {};
  const chatId = meta.chatId as string | undefined;
  const channelId = meta.channelId as string | undefined;
  if (!chatId || !channelId) return;

  const fileActions = (note.actions ?? []).filter((a): a is FileAction => a.type === "file");
  const attachments = [] as Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  for (const action of fileActions) {
    try {
      const file = await this.tools.files.read(action.fileId);
      attachments.push({ buffer: file.data, filename: file.fileName, mimeType: file.mimeType });
    } catch (e) {
      console.error("LinkedIn attachment read failed", action.fileId, e);
    }
  }

  const sent = await this.tools.linkedin.sendMessage({
    channelId,
    chatId,
    text: note.content ?? "",
    attachments,
  });

  return {
    key: `message-${sent.id}`,
    externalContent: sent.text,
  };
}
```

If `tools.linkedin.sendMessage` doesn't currently accept `attachments`, extend it (it's a private tool — modify in `workers/api/src/twist/tools/linkedin.ts` and its interface).

- [ ] **Step 3: Build and commit**

```bash
cd connectors/linkedin && pnpm build
git add connectors/linkedin/src/linkedin.ts workers/api/src/twist/tools/linkedin.ts libs/unipile/src/*.ts
git commit -m "feat(linkedin): send file actions as Unipile attachments"
```

---

## Task 20: LinkedIn — replace markdown-link attachments with `fileRef` + implement `downloadAttachment`

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts:700-722`

- [ ] **Step 1: Replace the markdown-link suffix**

Delete the existing block (lines ~700–719 in the exploration) that builds `attachmentSuffix` from markdown. Replace with `fileRef` actions:

```typescript
const actions: Action[] = msg.attachments.map((a) => ({
  type: ActionType.fileRef,
  ref: `${msg.id}:${a.id}`,
  fileName: a.name ?? "attachment",
  fileSize: a.byteSize ?? null,
  mimeType: a.contentType ?? "application/octet-stream",
}));

return {
  thread: { source: threadSource },
  key: `message-${msg.id}`,
  created: msg.sentAt,
  content: msg.text,  // no longer appending attachmentSuffix
  contentType: "text",
  author,
  actions,
};
```

(Confirm the inline note shape accepts `actions`. If not, route through `tools.plot.createNote`.)

- [ ] **Step 2: Implement `downloadAttachment`**

```typescript
async downloadAttachment(ref: string): Promise<{ body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }> {
  const [messageId, attachmentId] = ref.split(":");
  if (!messageId || !attachmentId) throw new Error(`Invalid LinkedIn ref: ${ref}`);

  // Use the same channel lookup pattern as Gmail/Slack — cached via tools.store
  const channelId = await this.findChannelForMessage(messageId);
  if (!channelId) throw new Error(`No LinkedIn channel for message ${messageId}`);

  const stream = await this.tools.linkedin.downloadAttachment({
    channelId,
    messageId,
    attachmentId,
  });
  return { body: stream.body, mimeType: stream.mimeType, fileName: stream.fileName };
}
```

`tools.linkedin.downloadAttachment` is new — add it in `workers/api/src/twist/tools/linkedin.ts` calling the Unipile SDK's attachment-download method.

- [ ] **Step 3: Build and commit**

```bash
cd connectors/linkedin && pnpm build
git add connectors/linkedin/src/linkedin.ts workers/api/src/twist/tools/linkedin.ts libs/unipile/src/*.ts
git commit -m "feat(linkedin): emit fileRef on inbound + downloadAttachment via Unipile"
```

---

## Task 21: Bump `public/` submodule pointer

**Files:**
- Modify: parent repo's submodule reference for `public/`

- [ ] **Step 1: Stage the submodule pointer**

Run: `git add public`

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: bump public submodule for connector attachment support"
```

This brings the parent repo onto the new commits made inside `public/`.

---

## Task 22: End-to-end manual verification (Gmail)

**Files:** none — exercise the running app.

- [ ] **Step 1: Bring up local DB and API**

Ensure the worktree DB is running (`bash scripts/worktree-db` if not), then start the API worker.

- [ ] **Step 2: Launch the app via the `run-app` skill**

Invoke the `run-app` skill (it handles isolated profile + dart-mcp connection).

- [ ] **Step 3: Outbound test**

In a Gmail thread, attach a small text file via the paperclip button, send. Verify within ~10s that the message arrives in the recipient inbox with the attachment readable.

- [ ] **Step 4: Inbound test**

Send yourself an email with an attachment from outside Plot. After sync, open the thread in Plot, click the attachment. Confirm it downloads/opens correctly.

- [ ] **Step 5: Failure-mode tests**

- Disable the Gmail channel and click an inbound attachment → expect "Source no longer available".
- Manually mutate a note's `actions[].ref` in the DB to an invalid value → expect retry button.

- [ ] **Step 6: Capture findings**

If anything is broken, file follow-up tasks against the same plan. Otherwise mark verification complete.

---

## Verification Checklist

After all tasks complete:

- [ ] `pnpm lint` clean repo-wide.
- [ ] `pnpm --filter @plotday/api test` passes.
- [ ] `cd public/twister && pnpm lint` clean.
- [ ] `cd public && pnpm validate-changesets` passes.
- [ ] Local end-to-end (Task 22) succeeds for Gmail.
- [ ] `docs/updates.md` has a user-facing bullet ("You can now attach files to Gmail/Slack/Linear/LinkedIn threads — they're delivered as native attachments, and attachments arriving from those systems open directly in Plot.") added to the top section.
- [ ] `docs/features.md` updated to mention attachment capabilities.
- [ ] `/finalize` skill run completed.

## Notes for the executing engineer

- This plan touches both the public submodule (`public/`) and the parent repo. Commits in `public/` need a corresponding submodule pointer bump in the parent (Task 21). If you commit in `public/` and forget the parent bump, the parent CI will still point at the old commit.
- Tasks 12–20 are largely independent per connector — they can be parallelized with different subagents. The shared dependencies are Tasks 1–11, which must complete first.
- The exact column names on `priority_twist`, the precise wrapper used in `entrypoint.ts`, and the file paths for some Flutter widgets need to be confirmed by reading the file before editing. The plan gives the canonical locations from the exploration, but adapt to what's actually there — don't invent column names.
- All new catch blocks for unexpected errors must call `captureException` per AGENTS.md, except inside twist/connector sandbox code where `console.error` is the only option.
