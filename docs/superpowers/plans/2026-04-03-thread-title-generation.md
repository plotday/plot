# Thread Title Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix AI title generation for threads so it reliably runs, works after offline sync, and has a clean client-side fallback derived from note content.

**Architecture:** Client keeps `title = null` and stores generous preview content. `displayTitle`/`displayPreview` derive from preview for immediate display. `save()` attempts AI title via `/summary`. Server generates AI title on sync when `title` is null, truncates preview. User-set titles are never overwritten.

**Tech Stack:** Dart/Flutter (client), TypeScript/Hono/Cloudflare Workers (API)

---

### Task 1: Add `_titleFromContent()` helper to Thread

**Files:**
- Modify: `apps/plot/lib/store/thread.dart:2259-2263` (near `displayTitle`)

This is a pure static helper with no dependencies. It derives a display title from content by stripping markdown, taking the first line, and truncating with word-boundary awareness.

- [ ] **Step 1: Add `_titleFromContent` static method**

Add this method to the `Thread` class, near the `displayTitle` getter (around line 2259):

```dart
/// Derives a display title from content (preview or note body).
/// Strips markdown, takes the first line, truncates at word boundary if > 60 chars.
/// Returns null if content is empty.
static String? _titleFromContent(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  final stripped = content.removeMarkdown(replaceLinksWithURL: false);
  final firstLine = stripped.split('\n').first.trim();
  if (firstLine.isEmpty) return null;
  if (firstLine.length <= 60) return firstLine;
  final lastSpace = firstLine.lastIndexOf(' ', 60);
  if (lastSpace > 0) {
    return '${firstLine.substring(0, lastSpace)}\u2026';
  }
  return '${firstLine.substring(0, 59)}\u2026';
}
```

Note: `removeMarkdown` is available as an extension on `String` from the `remove_markdown` package, already re-exported via `package:plot/util/string.dart`. The `\u2026` character is the ellipsis `…`.

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors related to the new method.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "feat: add _titleFromContent helper for deriving titles from content"
```

---

### Task 2: Add `_remainderPreview()` helper and `displayPreview` getter

**Files:**
- Modify: `apps/plot/lib/store/thread.dart:2259-2263` (near `displayTitle`)

This helper computes the preview text that follows after the derived title. It strips the title prefix from the preview string.

- [ ] **Step 1: Add `_remainderPreview` static method and `displayPreview` getter**

Add these to the `Thread` class, right after `_titleFromContent`:

```dart
/// Returns the portion of preview that comes after the derived title.
/// Used when title is null and displayTitle is derived from preview content.
static String? _remainderPreview(String preview, String derivedTitle) {
  // If title was truncated with ellipsis, recover the original prefix
  String prefix = derivedTitle;
  if (prefix.endsWith('\u2026')) {
    prefix = prefix.substring(0, prefix.length - 1);
  }

  // Find where the prefix ends in the stripped preview
  final stripped = preview.removeMarkdown(replaceLinksWithURL: false);
  final idx = stripped.indexOf(prefix);
  if (idx < 0) return null;

  var remainder = stripped.substring(idx + prefix.length).trim();

  // Clean up leading separators and whitespace
  remainder = remainder.replaceAll(RegExp(r'^[\s/]+'), '').trim();

  return remainder.isEmpty ? null : remainder;
}

String? get displayPreview {
  if (title != null) return preview; // AI/user title: preview from beginning
  if (preview == null) return null;
  final derivedTitle = _titleFromContent(preview);
  if (derivedTitle == null) return null;
  return _remainderPreview(preview!, derivedTitle);
}
```

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "feat: add displayPreview getter and _remainderPreview helper"
```

---

### Task 3: Update `displayTitle` to derive from preview

**Files:**
- Modify: `apps/plot/lib/store/thread.dart:2259-2263`

Update the existing `displayTitle` getter to use `_titleFromContent` when title is null.

- [ ] **Step 1: Replace `displayTitle` getter**

Find the current getter at line 2259:

```dart
  String get displayTitle {
    if (title != null) return title!;
    if (preview != null) return preview!;
    return draft ? '🤷' : 'Untitled';
  }
```

Replace with:

```dart
  String get displayTitle {
    if (title != null) return title!;
    final derived = _titleFromContent(preview);
    if (derived != null) return derived;
    return draft ? '🤷' : 'Untitled';
  }
```

The key change: instead of returning the raw preview as-is, we derive a proper title (first line, markdown-stripped, truncated at word boundary).

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "feat: displayTitle derives from preview via _titleFromContent"
```

---

### Task 4: Update UI to use `displayPreview`

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart:242` (ListTile subtitle)
- Modify: `apps/plot/lib/widget/thread.dart:674-678` (inline preview TextSpan)

Replace `activity.preview` with `activity.displayPreview` in the two places the thread widget shows preview text.

- [ ] **Step 1: Update ListTile subtitle**

Find at line 242:

```dart
      subtitle: activity.preview,
```

Replace with:

```dart
      subtitle: activity.displayPreview,
```

- [ ] **Step 2: Update inline preview TextSpan**

Find at lines 674-678:

```dart
                                  if (activity.preview != null &&
                                      activity.preview!.isNotEmpty &&
                                      activity.preview != activity.displayTitle)
                                    TextSpan(
                                      text: '  ${activity.preview}',
```

Replace with:

```dart
                                  if (activity.displayPreview != null &&
                                      activity.displayPreview!.isNotEmpty &&
                                      activity.displayPreview != activity.displayTitle)
                                    TextSpan(
                                      text: '  ${activity.displayPreview}',
```

- [ ] **Step 3: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/widget/thread.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/thread.dart
git commit -m "feat: use displayPreview instead of raw preview in thread widget"
```

---

### Task 5: Populate preview in `finalizeThreadDraft`

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart:895-948`

Change `finalizeThreadDraft` to set `title: null` and `preview: <generous content>` instead of the current behavior (title from first line, preview null).

- [ ] **Step 1: Update finalizeThreadDraft**

Find the current title generation and thread creation at lines 902-929:

```dart
    // Generate title from body (first line or first ~50 chars)
    String title = body
        .trim()
        .split('\n')
        .first
        .trim()
        .removeMarkdown(replaceLinksWithURL: false);
    if (title.isEmpty) {
      title = 'Untitled';
    }
    log.info('Finalizing draft with title: $title');

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.thread!.at != null;

    // Create Thread with title based on "Do Now" toggle
    final thread = widget.thread!.copyWith(
      title: Value(title),
      preview: const Value(null),
      draft: false,
```

Replace with:

```dart
    // Store generous preview from body content for client-side display
    // and server-side AI title generation. Title is left null — the client
    // derives displayTitle from preview, and the server generates an AI
    // title on sync.
    final previewContent = body.trim().isEmpty ? null : body.trim();
    log.info('Finalizing draft with preview-based title');

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.thread!.at != null;

    // Create Thread — title null signals server to generate AI title
    final thread = widget.thread!.copyWith(
      title: const Value(null),
      preview: Value(previewContent),
      draft: false,
```

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/widget/note_editor.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat: set title null and generous preview in finalizeThreadDraft"
```

---

### Task 6: Update move-to-new-thread command

**Files:**
- Modify: `apps/plot/lib/command/note.dart:349-354`

Change the move-to-new-thread command to set `title: null` (instead of `title: note.content`) and keep `preview: note.content`. Also remove the fire-and-forget AI title generation block.

- [ ] **Step 1: Update thread creation and remove fire-and-forget**

Find lines 348-372:

```dart
      // Create a new thread in the same priority with preview from note content
      final newThread = Thread(
        priority: parentThread.priority,
        draft: false,
        preview: note.content,
        title: note.content,
      );
      await newThread.save();

      // Move the note to the new thread and unarchive it
      await note.copyWith(threadId: newThread.id, clearArchivedAt: true).save();

      // Fire-and-forget AI title generation
      if (note.content != null && note.content!.trim().isNotEmpty) {
        newThread
            .generateTitle(note.content!)
            .then((title) async {
              if (title != newThread.title) {
                await newThread.copyWith(title: Value(title)).save();
              }
            })
            .catchError((Object e) {
              // Error already logged by generateTitle(), just ignore here
            });
      }
```

Replace with:

```dart
      // Create a new thread — title null signals AI generation in save() and sync.
      // Preview stores the note content for client-side display.
      final newThread = Thread(
        priority: parentThread.priority,
        draft: false,
        preview: note.content,
      );
      await newThread.save();

      // Move the note to the new thread and unarchive it
      await note.copyWith(threadId: newThread.id, clearArchivedAt: true).save();
```

The fire-and-forget block is removed because `Thread.save()` now handles AI title generation (Task 7).

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/command/note.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/note.dart
git commit -m "feat: move-to-new-thread uses null title with preview content"
```

---

### Task 7: Fix `generateTitle()` and `save()` in Thread

**Files:**
- Modify: `apps/plot/lib/store/thread.dart:3341-3373`

Fix `generateTitle()` to use `preview` as content source and update `save()` to leave title null on failure (server will generate on sync).

- [ ] **Step 1: Replace `generateTitle` and update `save` title generation block**

Find the current code at lines 3341-3373:

```dart
    // Generate a title on the first non-draft save
    if (title == null && !draft) {
      final generatedTitle = await generateTitle();
      log.info("Generated title: $generatedTitle");
      await copyWith(title: Value(generatedTitle)).save();
    }
  }

  Future<String> generateTitle([String noteContent = '']) async {
    // If no note content provided, return displayTitle as fallback
    if (noteContent.isEmpty) {
      return displayTitle;
    }

    try {
      final response = await api.post<Map<String, dynamic>>(
        '/summary',
        body: {'body': noteContent},
      );
      final generatedTitle = response['title'] as String?;

      if (generatedTitle != null && generatedTitle.isNotEmpty) {
        log.info("Generated title for activity $id: $generatedTitle");
        return generatedTitle;
      } else {
        log.info("API returned empty title for activity $id, using fallback");
        return displayTitle;
      }
    } catch (e, t) {
      log.warning("Error generating title for activity $id: $e\n$t");
      return displayTitle;
    }
  }
```

Replace with:

```dart
    // Generate AI title on first non-draft save.
    // If online, calls /summary API and sets title.
    // If offline/error, leaves title null — displayTitle derives from preview,
    // and the server will generate an AI title when the thread syncs.
    if (title == null && !draft) {
      final content = preview;
      if (content != null && content.trim().isNotEmpty) {
        try {
          final response = await api.post<Map<String, dynamic>>(
            '/summary',
            body: {'body': content},
          );
          final generatedTitle = response['title'] as String?;
          if (generatedTitle != null && generatedTitle.isNotEmpty) {
            log.info("Generated AI title for thread $id: $generatedTitle");
            await copyWith(title: Value(generatedTitle)).save();
          }
        } catch (e, t) {
          log.warning("AI title generation failed for thread $id (will retry on sync): $e\n$t");
        }
      }
    }
  }
```

The old `generateTitle()` method is no longer needed — remove it entirely. It was only called from `save()` (now inlined) and the fire-and-forget blocks (removed in Tasks 6 and 8).

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: No errors. If `generateTitle` is referenced elsewhere, the lint will catch it.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "fix: inline AI title generation in save(), remove generateTitle method"
```

---

### Task 8: Remove fire-and-forget in PriorityBloc.add()

**Files:**
- Modify: `apps/plot/lib/state/priority.dart:1169-1210`

Remove the redundant fire-and-forget `generateTitle()` block. `Thread.save()` now handles AI title generation.

- [ ] **Step 1: Remove fire-and-forget block and update docstring**

Find lines 1169-1209:

```dart
  /// Adds a thread by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published and asynchronously generates a title.
  /// Returns the saved thread.
  Future<Thread> add(
    Thread thread, {
    Note? note,
    bool assignNote = true,
  }) async {
    // Convert the draft to a non-draft
    final savedThread = thread.copyWith(draft: false);
    await savedThread.save();

    // Convert draft note to published if provided
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      var publishedNote = note.copyWith(threadId: savedThread.id, draft: false);

      // If the thread is a task and note assignment is requested, assign the
      // note to the current user — but only if no one is already assigned
      // (e.g. the user explicitly assigned someone else on the new thread page).
      if (savedThread.todo && assignNote && !publishedNote.isAssigned()) {
        publishedNote = publishedNote.assignTo(Base.actorId);
      }

      await publishedNote.save();

      // Asynchronously generate a better title using AI (fire and forget)
      // The thread is already saved with a fallback title, so this update
      // will happen in the background without blocking the UI
      savedThread
          .generateTitle(note.content!)
          .then((title) async {
            if (title != savedThread.title) {
              await savedThread.copyWith(title: Value(title)).save();
            }
          })
          .catchError((Object e) {
            // Error already logged by generateTitle(), just ignore here
          });
    }
```

Replace with:

```dart
  /// Adds a thread by converting the current draft to a non-draft.
  /// Creates a fresh draft for the priority afterward.
  /// If note is provided, converts it from draft to published.
  /// AI title generation is handled by Thread.save().
  /// Returns the saved thread.
  Future<Thread> add(
    Thread thread, {
    Note? note,
    bool assignNote = true,
  }) async {
    // Convert the draft to a non-draft
    final savedThread = thread.copyWith(draft: false);
    await savedThread.save();

    // Convert draft note to published if provided
    if (note != null &&
        note.content != null &&
        note.content!.trim().isNotEmpty) {
      var publishedNote = note.copyWith(threadId: savedThread.id, draft: false);

      // If the thread is a task and note assignment is requested, assign the
      // note to the current user — but only if no one is already assigned
      // (e.g. the user explicitly assigned someone else on the new thread page).
      if (savedThread.todo && assignNote && !publishedNote.isAssigned()) {
        publishedNote = publishedNote.assignTo(Base.actorId);
      }

      await publishedNote.save();
    }
```

- [ ] **Step 2: Run lint to verify**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "cleanup: remove fire-and-forget generateTitle from PriorityBloc.add"
```

---

### Task 9: Server-side AI title generation on sync

**Files:**
- Modify: `workers/api/src/app/summary.ts:56-97` (export `summarize`)
- Modify: `workers/api/src/app/sync/threads.ts:111-131` (POST handler)

When the sync POST receives a thread with `title` null/missing and `preview` present, generate an AI title and truncate the preview.

- [ ] **Step 1: Export the `summarize` function from summary.ts**

In `workers/api/src/app/summary.ts`, change the `summarize` function from private to exported at line 56:

```typescript
async function summarize(ai: Ai, body: string) {
```

Replace with:

```typescript
export async function summarize(ai: Ai, body: string) {
```

- [ ] **Step 2: Add `titleFromContent` helper to thread-helpers.ts**

In `workers/api/src/twist/tools/plot/thread-helpers.ts`, add this function after `cleanTitle` (after line 230):

```typescript
/**
 * Derives a display title from content. Strips markdown, takes the first line,
 * truncates at word boundary if > 60 chars. Server-side equivalent of the
 * client's _titleFromContent.
 */
export function titleFromContent(content: string | null | undefined): string | null {
  if (!content?.trim()) return null;
  const stripped = stripMarkdown(content).replace(/\s+/g, " ").trim();
  const firstLine = stripped.split("\n")[0].trim();
  if (!firstLine) return null;
  if (firstLine.length <= 60) return firstLine;
  const lastSpace = firstLine.lastIndexOf(" ", 60);
  if (lastSpace > 0) {
    return firstLine.substring(0, lastSpace) + "\u2026";
  }
  return firstLine.substring(0, 59) + "\u2026";
}
```

- [ ] **Step 3: Update POST /sync/threads to generate title when null**

In `workers/api/src/app/sync/threads.ts`, replace the POST handler (lines 111-131):

```typescript
// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();

  const threadData = body.thread || body;
  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread", {
      user_id: c.var.user.id,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  notifySync(c, threadData.priority_id);

  return c.json(result as any);
});
```

Replace with:

```typescript
// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();

  const threadData = body.thread || body;
  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  // Generate AI title when client sends title=null with preview content
  if (
    !threadData.title &&
    threadData.preview &&
    typeof threadData.preview === "string" &&
    threadData.draft !== true
  ) {
    try {
      const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");
      if (aiAllowed.allowed) {
        const providerConfig = await loadBuiltinProviderConfig(c.var.db, c.var.user.id, c.env);
        let aiTitle: string | null = null;

        if (providerConfig) {
          aiTitle = await summarizeWithProvider(providerConfig, threadData.preview);
        }
        if (!aiTitle) {
          const result = await summarize(c.env.AI, threadData.preview);
          aiTitle = result.title;
        }

        if (aiTitle) {
          recordAiUsage(c.env, c.var.user.id, "note_processing");
          threadData.title = aiTitle;
        }
      }
    } catch (error) {
      // AI failure is non-fatal — fall through to titleFromContent
      console.error("[sync/threads] AI title generation failed:", error);
    }

    // Fallback: derive title from content if AI didn't produce one
    if (!threadData.title) {
      threadData.title = titleFromContent(threadData.preview) ?? "Untitled";
    }

    // Truncate preview for storage now that title is set
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread", {
      user_id: c.var.user.id,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  notifySync(c, threadData.priority_id);

  return c.json(result as any);
});
```

- [ ] **Step 4: Update imports in threads.ts**

Add the new imports at the top of `workers/api/src/app/sync/threads.ts`:

```typescript
import { checkAiLimit, recordAiUsage } from "../../utils/ai-limits";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../../utils/ai-provider";
import { summarize } from "../summary";
import { titleFromContent, createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
```

The existing import of `cleanTitle` from `../../twist/tools/plot/thread` should remain.

- [ ] **Step 5: Run lint to verify**

Run: `cd workers/api && pnpm lint`
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/summary.ts workers/api/src/app/sync/threads.ts workers/api/src/twist/tools/plot/thread-helpers.ts
git commit -m "feat: server generates AI title on sync when title is null"
```

---

### Task 10: Verify and fix the DB constraint interaction

**Files:**
- No file changes expected — this is a verification step

The server DB has `CHECK (draft = TRUE OR (title IS NOT NULL AND title != ''))` on the `thread` table. The sync POST handler (Task 9) always resolves title before calling `upsert_thread`, so the constraint is satisfied. But we need to verify:

1. The client sync sends the thread data correctly (title null, preview populated)
2. The `upsert_thread` function receives a non-null title after the handler processes it

- [ ] **Step 1: Verify the upsert_thread function handles the flow**

Read `libs/db/schema/90-user-schema/80-upsert_thread.sql` and confirm:
- On INSERT: `COALESCE(p_thread ->> 'title', p_defaults ->> 'title')` — since the handler always sets `threadData.title`, this will be non-null.
- On UPDATE (conflict): `CASE WHEN p_thread ? 'title' THEN p_thread ->> 'title' ...` — the title key is present and non-null after handler processing.

No code changes needed if the handler correctly sets title before the RPC call.

- [ ] **Step 2: Verify the client doesn't send title in the key when null**

Check how the Drift sync serializes null fields. If the client omits the `title` key entirely when null (rather than sending `title: null`), the upsert ON CONFLICT path would keep the existing title — which is correct for subsequent syncs after the server has already set a title.

Run: `cd apps/plot && flutter analyze`
Expected: No errors across the full app.

- [ ] **Step 3: Commit (only if changes were needed)**

If any adjustments were needed:
```bash
git add -A && git commit -m "fix: ensure DB constraint compatibility with null title flow"
```

---

### Task 11: Run finalize checklist

- [ ] **Step 1: Run /finalize**

Run the `/finalize` skill to execute the full finalization checklist:
1. Lint all changed packages
2. Verify backwards compatibility (old clients with title still work, server handles both null and non-null title)
3. Check error capture (AI failures in sync handler should use captureException)
4. Update docs if needed

- [ ] **Step 2: Fix any issues found**

Address any lint errors, missing error capture, or backwards compatibility issues.

- [ ] **Step 3: Final commit**

```bash
git add -A && git commit -m "chore: finalize thread title generation changes"
```
