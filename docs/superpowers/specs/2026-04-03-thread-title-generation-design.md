# Thread Title Generation Design

## Problem

1. AI title generation doesn't always run. The `Thread.save()` method calls `generateTitle()` with no arguments, so `noteContent` defaults to `''` and the method immediately returns `displayTitle` without ever calling the `/summary` API.
2. When AI title generation isn't available (offline, API failure, rate limited), the fallback title is poor — just "Untitled" or the raw preview. It should derive a clean title from the first line of note content, with the preview picking up where the title left off.
3. The `preview` field isn't populated for client-created threads, so the list tile preview is empty until server sync.
4. When a thread is created offline, it never gains an AI title after syncing — the client sets a truncated title and the server has no signal to replace it.

## Key Insight: Title Null Means "Generate One"

The `title` field is nullable in the local DB (Drift) and the server DB. The server has a constraint (`thread_title_required_when_not_draft`) but it's enforced at INSERT time — the sync API can generate a title before passing data to `upsert_thread`.

By keeping `title = null` on the client when no AI title has been generated and no user-explicit title has been set, we get a clean signal:

- `title = null` → client displays from `preview`, server generates AI title on sync
- `title = <string>` → user or AI set it explicitly, server preserves it

This handles offline gracefully: the client works fine with `displayTitle` derived from preview, and when it eventually syncs, the server generates an AI title.

## Design

### 1. Client: Keep title null, store generous preview

**File:** `apps/plot/lib/widget/note_editor.dart` — `finalizeThreadDraft()`

Instead of setting `title` from the first line and `preview: null`, do the opposite:

- `title: null` (no title set yet — signal for server to generate)
- `preview: <generous content>` — store much more than the 100 chars currently used by the server's `createPreviewFromMarkdown`. Store the full note content (or a generous amount, e.g. 2000 chars) so both client display and server AI generation can work from it.

The preview field serves double duty:
1. Client uses it for `displayTitle` and `displayPreview`
2. Server uses it as input for AI title generation, then truncates it

**File:** `apps/plot/lib/command/note.dart` — move-to-new-thread

Same pattern: set `title: null`, `preview: note.content`.

### 2. `_titleFromContent()` static helper

**File:** `apps/plot/lib/store/thread.dart`

Derives a display title from content (used by `displayTitle` when `title` is null):

- Strip markdown formatting
- Take the first line
- If <= 60 chars: use as-is
- If > 60 chars: truncate before the last space before the 60-char limit, add ellipsis
- Return null if empty

```dart
static String? _titleFromContent(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  final stripped = content.removeMarkdown(replaceLinksWithURL: false);
  var firstLine = stripped.split('\n').first.trim();
  if (firstLine.isEmpty) return null;
  if (firstLine.length <= 60) return firstLine;
  final lastSpace = firstLine.lastIndexOf(' ', 60);
  if (lastSpace > 0) {
    return '${firstLine.substring(0, lastSpace)}\u2026';
  }
  return '${firstLine.substring(0, 59)}\u2026';
}
```

### 3. Update `displayTitle` getter

**File:** `apps/plot/lib/store/thread.dart`

```dart
String get displayTitle {
  if (title != null) return title!;
  final derived = _titleFromContent(preview);
  if (derived != null) return derived;
  return draft ? '\u{1f937}' : 'Untitled';
}
```

### 4. New `displayPreview` getter

**File:** `apps/plot/lib/store/thread.dart`

```dart
String? get displayPreview {
  if (title != null) return preview; // AI/user title: preview from beginning
  if (preview == null) return null;
  // Fallback: preview picks up after the derived title
  final derivedTitle = _titleFromContent(preview);
  if (derivedTitle == null) return null;
  return _remainderPreview(preview!, derivedTitle);
}
```

`_remainderPreview` strips the title prefix from the preview string and returns what's left (trimmed), or null if nothing remains. Since `_titleFromContent` may have truncated with ellipsis, the method strips the ellipsis to recover the original prefix, finds that prefix in the preview, and returns everything after it. The result is cleaned up (leading separators like ` / ` trimmed).

### 5. Server: Generate title on sync when null

**File:** `workers/api/src/app/sync/threads.ts` — `POST /sync/threads`

When `title` is null/missing and `preview` is present and `draft` is false:

1. Attempt AI title generation using the existing `summarize()` function from `summary.ts` (or the same AI call), with `preview` as input
2. On success: set `threadData.title` to the AI result
3. On failure/rate-limit: set `threadData.title` using a server-side `titleFromContent()` equivalent (first line, truncate at 60 chars)
4. Truncate `threadData.preview` to 100 chars (matching current `createPreviewFromMarkdown` behavior)

This ensures:
- The DB constraint is satisfied (title is always non-null for non-drafts)
- AI titles are generated even for threads created offline
- Preview is normalized to a reasonable size for storage/sync

The AI limit check should use `checkAiLimit` (user-level) since we have the user ID from the sync context.

### 6. Fix `generateTitle()` in `save()`

**File:** `apps/plot/lib/store/thread.dart`

The `save()` method currently calls `generateTitle()` with no content on first non-draft save. Update this to:

- Still attempt AI title generation (for online case)
- Use `preview` as the content source (no need to fetch notes separately — preview is now populated)
- On success: set `title` to the AI result
- On failure: leave `title` null (server will generate on sync, client displays from preview)

```dart
// Generate a title on the first non-draft save
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
        await copyWith(title: Value(generatedTitle)).save();
      }
      // If API returns empty, leave title null — server will generate on sync
    } catch (e, t) {
      log.warning("Error generating title for thread $id: $e\n$t");
      // Leave title null — displayTitle derives from preview, server generates on sync
    }
  }
}
```

### 7. UI updates

**File:** `apps/plot/lib/widget/thread.dart`

Replace `activity.preview` with `activity.displayPreview` in:
- Line ~242: `subtitle: activity.displayPreview`
- Lines ~674-678: the inline preview TextSpan condition and text

### 8. Cleanup

Remove redundant fire-and-forget `generateTitle()` calls:
- `apps/plot/lib/state/priority.dart` lines ~1197-1209: remove the async title generation block in `PriorityBloc.add()`
- `apps/plot/lib/command/note.dart` lines ~360-372: remove the async title generation block in move-to-new-thread

These are no longer needed because `Thread.save()` handles AI title generation using `preview` as input.

Remove `_getFirstNoteContent()` helper — no longer needed since we use `preview`.

## Data Flow

```
Client creates thread:
  title: null, preview: <generous note content>
  → displayTitle derives from preview (first line, truncated)
  → displayPreview shows remainder after title
  → save() attempts AI title via /summary API
    → Success: title set, displayTitle uses it, displayPreview = preview
    → Failure (offline/error): title stays null, display from preview

Thread syncs to server:
  → POST /sync/threads receives title: null, preview: <content>
  → Server generates AI title from preview
    → Success: stores AI title + truncated preview
    → Failure: stores fallback title (first line) + truncated preview
  → Thread syncs back to client with title + truncated preview

User explicitly edits title:
  → title set to user's value, never overwritten by server
```

## Files Changed

| File | Change |
|------|--------|
| `apps/plot/lib/store/thread.dart` | Update `save()` title generation to use preview, add `_titleFromContent()`, `_remainderPreview()`, update `displayTitle`, add `displayPreview` |
| `apps/plot/lib/widget/note_editor.dart` | Set `title: null`, `preview: <generous content>` in `finalizeThreadDraft()` |
| `apps/plot/lib/widget/thread.dart` | Use `displayPreview` instead of `preview` |
| `apps/plot/lib/state/priority.dart` | Remove fire-and-forget `generateTitle()` call |
| `apps/plot/lib/command/note.dart` | Set `title: null`, `preview: note.content` in move-to-new-thread |
| `workers/api/src/app/sync/threads.ts` | Generate AI title when `title` is null, truncate preview |
| `workers/api/src/app/summary.ts` | Extract `summarize()` or reuse for sync-time title generation |
