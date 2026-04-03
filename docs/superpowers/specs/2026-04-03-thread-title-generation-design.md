# Thread Title Generation Design

## Problem

1. AI title generation doesn't always run. The `Thread.save()` method calls `generateTitle()` with no arguments, so `noteContent` defaults to `''` and the method immediately returns `displayTitle` without ever calling the `/summary` API.
2. When AI title generation isn't available (offline, API failure, rate limited), the fallback title is poor — just "Untitled" or the raw preview. It should derive a clean title from the first line of note content, with the preview picking up where the title left off.
3. The `preview` field isn't populated for client-created threads, so the list tile preview is empty until server sync.

## Design

### 1. Make `generateTitle()` self-sufficient

**File:** `apps/plot/lib/store/thread.dart`

Change `generateTitle()` to fetch its own note content when none is provided:

```dart
Future<String> generateTitle([String? noteContent]) async {
  noteContent ??= await _getFirstNoteContent();
  if (noteContent == null || noteContent.trim().isEmpty) {
    return _titleFromContent(preview) ?? 'Untitled';
  }

  try {
    final response = await api.post<Map<String, dynamic>>(
      '/summary',
      body: {'body': noteContent},
    );
    final generatedTitle = response['title'] as String?;
    if (generatedTitle != null && generatedTitle.isNotEmpty) {
      return generatedTitle;
    }
  } catch (e, t) {
    log.warning("Error generating title for activity $id: $e\n$t");
  }

  return _titleFromContent(noteContent) ?? 'Untitled';
}
```

Add a private helper to fetch the first note:

```dart
Future<String?> _getFirstNoteContent() async {
  final notes = await Note.getForThread(id, draft: false);
  if (notes.isEmpty) return null;
  notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return notes.first.content;
}
```

The `save()` method's existing call to `generateTitle()` (line ~3343) now works correctly since the method fetches its own content.

### 2. `_titleFromContent()` static helper

**File:** `apps/plot/lib/store/thread.dart`

Derives a display title from markdown content:

- Strip markdown formatting
- Take the first line
- If <= 60 chars: use as-is
- If > 60 chars: truncate before the last space before the 60-char limit, add ellipsis
- Return null if input is empty

```dart
static String? _titleFromContent(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  final stripped = content.removeMarkdown(replaceLinksWithURL: false);
  var firstLine = stripped.split('\n').first.trim();
  if (firstLine.isEmpty) return null;
  if (firstLine.length <= 60) return firstLine;
  final lastSpace = firstLine.lastIndexOf(' ', 60);
  if (lastSpace > 0) {
    return '${firstLine.substring(0, lastSpace)}...';
  }
  return '${firstLine.substring(0, 59)}...';
}
```

### 3. Populate preview at thread creation time

**File:** `apps/plot/lib/widget/note_editor.dart` — `finalizeThreadDraft()`

Currently sets `preview: const Value(null)`. Change to derive preview from the note body, matching the server's `createPreviewFromMarkdown` behavior:

- Strip markdown
- Strip raw URLs
- Replace newlines with ` / ` separator
- Collapse whitespace
- Truncate to 100 chars

This can reuse or mirror the `removeMarkdown` extension plus additional cleanup. The preview should be set from the full body content, not just the first line.

### 4. Update `displayTitle` getter

**File:** `apps/plot/lib/store/thread.dart`

```dart
String get displayTitle {
  if (title != null) return title!;
  final derived = _titleFromContent(preview);
  if (derived != null) return derived;
  return draft ? '\u{1f937}' : 'Untitled';
}
```

When title is null, derives from `preview` (which is now reliably populated per change #3).

### 5. New `displayPreview` getter

**File:** `apps/plot/lib/store/thread.dart`

```dart
String? get displayPreview {
  if (title != null) return preview; // AI title: preview starts from beginning
  if (preview == null) return null;
  // Fallback: preview picks up after the derived title
  final derivedTitle = _titleFromContent(preview);
  if (derivedTitle == null) return null;
  return _remainderPreview(preview!, derivedTitle);
}
```

`_remainderPreview` strips the title prefix from the preview string and returns what's left (trimmed), or null if nothing remains. Since `_titleFromContent` may have truncated with ellipsis, the method strips the ellipsis to recover the original prefix, finds that prefix in the preview, and returns everything after it. The result is cleaned up (leading separators like ` / ` trimmed).

### 6. UI updates

**File:** `apps/plot/lib/widget/thread.dart`

Replace `activity.preview` with `activity.displayPreview` in:
- Line ~242: `subtitle: activity.displayPreview`
- Lines ~674-678: the inline preview TextSpan condition and text

### 7. Cleanup

Remove redundant fire-and-forget `generateTitle()` calls:
- `apps/plot/lib/state/priority.dart` lines ~1197-1209: remove the async title generation block in `PriorityBloc.add()`
- `apps/plot/lib/command/note.dart` lines ~360-372: remove the async title generation block in move-to-new-thread

These are no longer needed because `Thread.save()` calls `generateTitle()` which now fetches its own content.

## Files Changed

| File | Change |
|------|--------|
| `apps/plot/lib/store/thread.dart` | Fix `generateTitle()`, add `_titleFromContent()`, `_getFirstNoteContent()`, `_remainderPreview()`, update `displayTitle`, add `displayPreview` |
| `apps/plot/lib/widget/note_editor.dart` | Populate `preview` in `finalizeThreadDraft()` |
| `apps/plot/lib/widget/thread.dart` | Use `displayPreview` instead of `preview` |
| `apps/plot/lib/state/priority.dart` | Remove fire-and-forget `generateTitle()` call |
| `apps/plot/lib/command/note.dart` | Remove fire-and-forget `generateTitle()` call |
