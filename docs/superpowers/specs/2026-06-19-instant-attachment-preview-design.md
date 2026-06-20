# Instant local-data previews for file attachments

**Date:** 2026-06-19
**Status:** Approved (design), implementing

## Problem

When a user attaches a file, the preview/row doesn't appear until the upload to
the server completes. On a slow connection or with a large file the preview lags
by seconds. The pasted-image path already solves this (`_handleImagePaste` in
`lib/widget/note_editor.dart`): it inserts a placeholder built from local bytes,
shows the thumbnail immediately, and uploads in the background, swapping the
placeholder for the real attachment once the server returns a file id.

The **"Attach file"** command (`lib/command/attach_file.dart`) and the
**"Take photo"** command (`lib/command/take_photo.dart`) do **not** do this —
they `await api.uploadFile(...)` *before* the attachment is added to the editor,
so nothing shows until the upload finishes.

## Goal

Make every local-file attach path show its preview/row immediately from local
data, uploading in the background — matching the paste experience. Cover the
file picker (images → instant thumbnail; non-images → instant icon+name row) and
the camera. Close the latent correctness gap where a placeholder's fake
`__pending_` file id could be published/synced if the user sends before the
upload finishes.

## Approach

The optimistic machinery (placeholder insert, `FilePreviewCache`, by-id swap,
error cleanup, drain) is the same regardless of where the bytes came from. We
extract it into a small, injectable coordinator and make the commands thin
pickers that hand local data to the editor.

### New unit: `AttachmentUploader` (+ `LocalAttachment`)

New file `lib/widget/attachment_uploader.dart`.

`LocalAttachment` — a value object describing a picked file before upload:

```dart
class LocalAttachment {
  final String fileName;
  final String mimeType;   // provisional (extension-derived); server is authoritative on swap
  final int fileSize;
  final Uint8List? bytes;  // present on web, and for camera; null for native non-image picks
  final String? filePath;  // present on native; '' / null on web
  bool get isImage => mimeType.startsWith('image/');
}
```

`AttachmentUploader` — coordinator that owns the optimistic flow. All external
dependencies are injected so it is unit-testable with no widget tree and no
network:

```dart
AttachmentUploader({
  required String Function() getPriorityId,
  required List<UserAction> Function() getActions,
  required void Function(List<UserAction>) setActions,
  required void Function(String message) onError,   // wired to context.showToast
  Future<Map<String, dynamic>> Function({
    required String filePath,
    required String fileName,
    required String priorityId,
    Uint8List? bytes,
  }) upload = api.uploadFile,                        // injectable seam for tests
  Future<(int, int)?> Function(Uint8List) getDimensions = getImageDimensions,
  bool Function() isMounted = _alwaysTrue,
});
```

Behaviour:

- `attachAll(List<LocalAttachment>)`:
  1. Build one placeholder `FileUserAction` per item with a unique pending id
     (`__pending_<seq>` from a monotonic counter so a synchronous batch never
     collides), `imageWidth/Height = null`.
  2. For image items, put the preview bytes in `FilePreviewCache` keyed by the
     pending id. Native images with only a `filePath` are read once here (guarded
     by `!kIsWeb`); web items already carry bytes.
  3. Insert **all** placeholders in a **single** `setActions` call (correct for
     multi-select; avoids the stale-read clobber that sequential inserts would
     cause in new-thread mode).
  4. Kick off one background upload per item (tracked in `_pending`), then
     return — the caller (command) does not await uploads.
- Per-item background task `_uploadOne`:
  - For images, compute dimensions off the critical path (does not delay the
    placeholder).
  - `upload(...)` with `bytes` when present, else stream from `filePath`.
  - On success: build the real `FileUserAction` from the server response
    (authoritative `fileId`/`fileName`/`fileSize`/`mimeType`) plus locally
    computed dims; `FilePreviewCache.rekey(pendingId, realFileId)`; replace the
    placeholder **by pending id** in a read-modify-write over the live
    `getActions()`. If the placeholder is gone (user removed it mid-upload),
    evict the real cache entry and drop the orphan (server-side GC).
  - On `NetworkException` / other errors: remove the placeholder by id, evict the
    cache entry, `onError(message)`. Report unexpected errors with
    `Tracker.captureException` (network/offline is expected — no capture).
  - `finally`: remove the entry from `_pending`.
- `drainPending()` → `await Future.wait(_pending.values)`; after it returns every
  placeholder has been swapped to a real action or removed, so the action list
  contains no `__pending_` ids.
- `hasPending` getter.

The coordinator operates on the editor's action list via `getActions`/
`setActions`, so it does not own list state and never fights user edits (the
remove-attachment button still routes through the editor as today). The
new-thread `onDraftChanged` round-trip has a one-frame read-staleness that the
existing single-file paste already tolerates; batching the placeholder insert
and spacing swaps by network completion keeps multi-file safe in practice. This
limitation is documented in the code.

### Editor changes (`lib/widget/note_editor.dart`)

- Construct one `AttachmentUploader` in the State, wired to `_currentActions`
  (get), `_setCurrentActions` (set), priority-id resolution (new-thread vs
  note mode, as `_handleImagePaste` does today), `context.showToast` for
  `onError`, and `() => mounted` for `isMounted`. Callbacks read `context`
  lazily at call time.
- `_handleImagePaste(bytes)` becomes a thin caller that builds a single
  `LocalAttachment` (image/png) and calls `uploader.attachAll([...])`. The
  placeholder now appears synchronously (dims no longer awaited before insert).
- Add public `attachLocalFiles(List<LocalAttachment>)` → `uploader.attachAll`.
- `_finalizeNoteDraft` and `finalizeThreadDraft`: `await uploader.drainPending()`
  at the top, before snapshotting actions. This is the single guarantee that no
  `__pending_` id is ever published/synced (covers note-mode reply and
  new-thread send — both run inside the editor State).
- Local **draft autosave is intentionally untouched**: a `draft: true` row may
  hold a `__pending_` id (harmless, local only; lets the attachment survive
  navigation; the editor swaps it when the upload lands). Only publish drains.
- Rewire the `AttachFile` / `TakePhoto` construction sites (note-mode and
  new-thread-mode `build()`) to pass `onAttach: attachLocalFiles`. The old
  per-command `api.uploadFile` → `onLinksChanged` path is removed for these two.

### Command changes — thin pickers

`lib/command/attach_file.dart` (`AttachFile`):
- New interface: `AttachFile({ required void Function(List<LocalAttachment>) onAttach })`.
- `run()`: open `FilePicker.pickFiles(allowMultiple: true, withData: kIsWeb)`,
  skip files over 25 MB (keep the existing "skipped (too large)" message), build
  a `LocalAttachment` per remaining file (mime via `lookupMimeType(name)` ??
  `application/octet-stream`; web → `bytes`; native → `filePath`), call
  `onAttach(list)`, return `CommandDone` immediately. Remove `_uploadFile`,
  `priorityId`, `currentLinks`, `onLinksChanged`.

`lib/command/take_photo.dart` (`TakePhoto`):
- New interface: `TakePhoto({ required void Function(List<LocalAttachment>) onAttach })`.
- `run()`: open camera; on success build a single image `LocalAttachment`
  (path + mime via `lookupMimeType(name)` ?? `image/jpeg`), call `onAttach`,
  return `CommandDone`. Remove the upload + `onLinksChanged` path. Keep the
  camera-open error handling.

## Files

- **New** `lib/widget/attachment_uploader.dart` — `LocalAttachment`,
  `AttachmentUploader`.
- `lib/widget/note_editor.dart` — own the uploader; thin `_handleImagePaste`;
  add `attachLocalFiles`; drain in both finalize methods; rewire command
  construction.
- `lib/command/attach_file.dart` — thin picker.
- `lib/command/take_photo.dart` — thin picker.
- **New** `test/widget/attachment_uploader_test.dart` — coordinator unit tests.

## Testing (TDD, coordinator-level)

Unit-test `AttachmentUploader` with a list-backed `getActions`/`setActions`
(synchronously consistent), a `Completer`-driven fake `upload`, and a fake
`getDimensions`:

1. **Instant insert** — `attachAll` inserts the placeholder before the upload
   completer resolves; the placeholder's id starts with `__pending_`.
2. **Image cached** — an image item's bytes are in `FilePreviewCache` under the
   pending id immediately; a non-image item caches nothing and still inserts a
   row.
3. **Swap on success** — resolving the upload replaces the placeholder with a
   `FileUserAction` carrying the server `fileId`; cache rekeyed to the real id.
4. **Failure** — a throwing/`NetworkException` upload removes the placeholder,
   evicts the cache entry, and calls `onError`; no orphan action remains.
5. **Removed mid-upload** — if the placeholder is absent at swap time, the real
   action is not re-added and its cache entry is evicted.
6. **Drain before publish** — with an upload in flight, `drainPending()` waits;
   after it resolves the action list holds the real id and no `__pending_` id;
   a failed upload drains to an action list without that attachment.
7. **Multi-file** — `attachAll` with N items inserts N placeholders in one
   `setActions`; N concurrent uploads resolve to N real actions.

Plus a `flutter analyze` clean run. Full-editor wiring (command → editor →
uploader) and the native file-read branch are verified by running the app
(`run-app`) since they need the picker/engine; the algorithmic core is covered
by the unit tests above.

## Out of scope

- Twister/SDK, database schema, and worker changes (none needed).
- Reworking the new-thread `onDraftChanged` round-trip (the one-frame staleness
  is pre-existing and tolerated; documented, not re-architected here).
- A "1 attachment failed to upload" summary on publish-after-failed-drain (the
  per-file error toast already fires); could be a later refinement.
