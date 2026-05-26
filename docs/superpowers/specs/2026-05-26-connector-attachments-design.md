# Connector Attachment Support

**Date:** 2026-05-26
**Status:** Approved design — ready for implementation plan

## Goal

End-to-end attachment support for connectors. A user can attach a file to a note in Plot and have the connector deliver it to the source system (e.g. Gmail sends an email with the attachment). Attachments arriving from source systems (Gmail, Slack, Linear, LinkedIn) appear as first-class attachments on notes in Plot, opened and downloaded through Plot.

In scope for v1:
- Outbound (Plot → source) for Gmail, Slack, Linear, LinkedIn.
- Inbound (source → Plot) for Gmail, Slack, Linear, LinkedIn.
- SDK extension in `public/twister/` so other connectors can adopt the same surface.
- Flutter rendering of both attachment kinds in note views, plus the file-attach affordance in the composer (build if absent).

## Architecture

Two attachment action types on notes, used in opposite directions:

| Action type | Direction | Storage | Lifetime |
|---|---|---|---|
| `ActionType.file` (existing) | Outbound | R2 `FILES_BUCKET` | Indefinite — kept forever after send |
| `ActionType.fileRef` (new) | Inbound | Source-system only (no Plot copy) | Tied to source — revoked connection ⇒ unavailable |

The two paths are independent. Inbound attachments are **not** copied into R2. Outbound attachments are **not** converted to `fileRef` after send. This matches the user's preferences ("reference the source — losing access when revoked is a plus" for inbound; "keep R2 copy indefinitely" for outbound).

On inbound download, Plot's API server holds the connector OAuth tokens and proxies/redirects per request, so the user's device never needs source-system credentials. Signed URLs can have short TTLs because Plot mints them fresh on each click.

## SDK changes (`public/twister/src/`)

### `plot.ts`

Extend the `ActionType` enum and the `Action` union:

```ts
export enum ActionType {
  // ... existing values
  fileRef = "fileRef",
}

// Added variant in the Action union:
| {
    type: ActionType.fileRef;
    ref: string;             // opaque; only the owning connector interprets
    fileName: string;
    fileSize: number | null;
    mimeType: string;
    imageWidth?: number | null;
    imageHeight?: number | null;
  }
```

`ref` encoding is left to each connector (e.g. `"msgId:partId"` for Gmail, `"file_id"` for Slack). Clients treat it as opaque.

### `connector.ts`

New optional abstract method on `Connector`:

```ts
abstract downloadAttachment?(ref: string): Promise<
  | { redirectUrl: string }
  | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }
>;
```

The connector returns either a fresh redirect URL (Linear S3, Slack public permalink) or a streamed body (Gmail must download from API; Slack `url_private` with bot token). Plot's resolver endpoint adapts both shapes to the HTTP response.

### Changeset

`public/.changeset/connector-attachments.md`:

```markdown
---
"@plotday/twister": minor
---

Added: ActionType.fileRef and Connector.downloadAttachment for source-hosted attachments. Connectors can now emit fileRef actions during inbound sync and serve their bytes on demand via downloadAttachment. Outbound attachments continue to use ActionType.file backed by Plot's R2 storage.
```

## Tool addition

New method on the Files tool, available to connectors as `this.tools.files.read`:

```ts
this.tools.files.read(fileId: string): Promise<{
  data: Uint8Array;
  fileName: string;
  mimeType: string;
  fileSize: number;
}>
```

Reads from `FILES_BUCKET`. Access control: the `fileId` must appear in `actions[]` on a note in a thread filed under a priority where the calling twist is installed. (This matches the existing `GET /files/:fileId` check, which already looks up `fileId` via `note.actions[].fileId` for priority access.) Throws `FileNotFoundError` if the R2 object is missing or out of scope.

Implementation lives in `workers/api/src/twist/tools/` alongside the existing tools. The public surface is added to `public/twister/src/tools/files.ts` (new file) and exported from the package.

## Outbound flow (Plot → source)

1. User attaches a file in the Plot composer. Flutter posts to existing `POST /files` and receives `{ fileId, fileName, fileSize, mimeType }`. (Flutter UI: see "Flutter UI" below.)
2. Client constructs a note with `actions: [{ type: "file", fileId, fileName, fileSize, mimeType, ... }]` and saves it through the existing note creation path.
3. Sync dispatches `onNoteCreated(note, thread)` on the owning connector.
4. The connector iterates `note.actions`, calls `this.tools.files.read(fileId)` for each `ActionType.file`, then posts to the source system (per-connector encoding in the table below).
5. The connector returns `NoteWriteBackResult` (existing shape).
6. The R2 object is **not** deleted and the `ActionType.file` action remains on the note.

If `tools.files.read` throws, the connector logs the error and returns `{}` for write-back; the existing key-based idempotency lets a future retry succeed.

## Inbound flow (source → Plot)

1. The connector receives webhook/sync data containing attachment metadata.
2. The connector creates a note (via `tools.plot.createNote` or the inline note shape returned from sync) with `actions: [{ type: "fileRef", ref, fileName, mimeType, fileSize, ... }]`.
3. Plot stores the note. No R2 write.
4. When the user opens the attachment, the client hits the new endpoint described below.

### Resolver endpoint

`GET /files/ref/:noteId/:actionIndex`

Behavior:

1. Load the note. If missing → 404.
2. Enforce priority access on the calling user (existing `assert_priority_access` pattern used by `/files/:fileId`).
3. Read the action at `actionIndex`. If it's not a `fileRef` → 400.
4. Resolve the owning connector via `note.link_id → link → priority_twist`. If no link / no connector / connection broken → 410 Gone.
5. Call `connector.downloadAttachment(ref)` on the twist runtime.
6. Map the return value:
   - `{ redirectUrl }` → `302 Location: <redirectUrl>`. `Content-Disposition` and `Content-Type` headers are set from the action's `fileName` / `mimeType` so browser downloads name the file correctly even after the redirect.
   - `{ body, mimeType, fileName? }` → stream the body with `Content-Type: <mimeType>` and `Content-Disposition: attachment; filename="<fileName>"` (falling back to the action's `fileName`).
7. If `downloadAttachment` throws → 502 Bad Gateway with a JSON error body; client surfaces "attachment unavailable, retry?".

The endpoint lives next to existing file routes in `workers/api/src/app/files.ts`.

## Flutter UI

### Composer

First step of implementation is to grep the Flutter composer for existing `ActionType.file` / `POST /files` usage. If a file-attach affordance already exists, skip composer work and only do the rendering changes below. Otherwise, build:
- A paperclip icon in the note composer toolbar that opens the system file picker.
- Upload-in-progress chip with name + size + remove button, posted to `POST /files`.
- On send, chips become `ActionType.file` entries in `note.actions`.

### Rendering

Both `file` and `fileRef` actions render identically in the note view:
- File icon based on `mimeType` family (image, pdf, doc, generic).
- Filename, size (if known).
- Inline image preview when `mimeType` starts with `image/` and dimensions are known.
- Tap behavior:
  - `file` → existing `/files/:fileId` download path.
  - `fileRef` → `/files/ref/:noteId/:actionIndex`.

For `fileRef` actions whose resolver returns 410, surface a "Source no longer available" state in place of the file row.

## Per-connector implementation

| Connector | Outbound (`onNoteCreated`) | Inbound (`downloadAttachment`) | `ref` encoding |
|---|---|---|---|
| **Gmail** | MIME multipart message with one base64-encoded part per file action; sent via existing Gmail API client | Stream from `gmail.users.messages.attachments.get` (must proxy through Plot — no public URL) | `msgId:partId` |
| **Slack** | `files.getUploadURLExternal` → PUT bytes → `files.completeUploadExternal`, then `chat.postMessage` with `file_ids` (or thread reply) | Redirect to fresh `permalink_public` if file is public; else stream `url_private` with bot token | `file_id` |
| **Linear** | `fileUpload` GraphQL mutation, then embed the asset URL in the comment body | Redirect to Linear's signed asset URL (short TTL — mint fresh on each call) | `attachment_id` |
| **LinkedIn** | Unipile `sendMessage` with `attachments` (multipart upload) | Stream via Unipile attachment download | `message_id:attachment_id` |

For each connector the inbound message/event parsing must also be updated to emit `fileRef` actions instead of the current "append markdown link" pattern (LinkedIn `linkedin.ts:700–719` is the existing template — it gets replaced).

## Error handling

| Failure | Behavior |
|---|---|
| `tools.files.read` for a fileId not on any accessible note | Throws `FileNotFoundError`. Connector logs, returns `{}` from `onNoteCreated`. Existing key-based retry can recover. |
| Connector's source API rejects upload (size, type, quota) | Connector logs and returns `{}`; later message edit/retry path applies. (Out-of-scope: surfacing the failure back to the Plot user in the composer.) |
| `downloadAttachment` throws auth error | Resolver returns 502; connector enters re-auth via existing daily sweep / `probe-auth-channels`. User sees "attachment unavailable" + standard re-auth banner once the channel is flagged. |
| Connection deleted | Resolver returns 410 Gone. Client renders the "Source no longer available" state. |
| `note.link_id` is null on a note that has a `fileRef` action | Resolver returns 410 (treat as orphaned). This shouldn't happen if connectors set `link_id` correctly during inbound sync. |

All unexpected errors in resolver, tool, and connector code go through `captureException` (PostHog) per project convention. Twist/connector sandbox code uses `console.error` only (no PostHog access).

## Out of scope (v1)

- Thumbnails / preview images for `fileRef` (always render via full download).
- Background "rehydrate to R2" of inbound attachments for offline access.
- Editing or replacing attachments on already-sent notes.
- Outbound streaming uploads larger than the existing `POST /files` 25 MB limit.
- Surfacing per-attachment send failures back to the Plot composer.
- Per-attachment access control beyond priority-level access (e.g. Linear's per-issue ACLs).

## Testing approach

- **Twister types:** TypeScript build of `public/twister/` and downstream packages must compile.
- **Tool:** Unit test `tools.files.read` access control — accessible fileId returns bytes, out-of-scope fileId throws, missing R2 object throws.
- **Resolver endpoint:** Integration test the four response paths (302 redirect, streamed body, 410 Gone, 502 connector error) against a fake connector.
- **Connectors:** Per-connector integration test exercising one outbound round-trip (mock source API, verify the expected attachment payload was constructed) and one inbound resolver call (mock source API, verify bytes/URL pass through).
- **Flutter:** Widget test the renderer for both action types. Manual `verify` skill run against the local app to attach a file to a Gmail thread and confirm receipt in a real Gmail inbox (end-to-end smoke).

## Open questions

None remaining for v1 scope. Implementation plan can proceed.
