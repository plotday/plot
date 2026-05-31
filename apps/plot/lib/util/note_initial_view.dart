import 'package:plot/store/store.dart';

/// True when [note] should be treated as unread, given a snapshot of the
/// thread's read state captured when the page opened.
///
/// [threadUnread] is the thread's `unread` flag and [readAt] its `readAt`,
/// both snapshotted before ThreadPage's mark-as-read timer resets them. A
/// fully-read thread (`threadUnread == false`) has no unread notes. With an
/// unread thread, a note is unread when it was created after the read
/// boundary (or there is no boundary yet).
bool noteIsUnread(
  Note note, {
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (!threadUnread) return false;
  return readAt == null || note.sourceCreatedAt.isAfter(readAt);
}

/// Whether [note] should start expanded (untruncated) on first paint.
///
/// A lone note is always expanded. With multiple notes, only unread notes
/// start expanded; read notes keep the default height-truncation.
bool noteInitiallyExpanded(
  Note note, {
  required int noteCount,
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (noteCount <= 1) return true;
  return noteIsUnread(note, threadUnread: threadUnread, readAt: readAt);
}

/// Index into [notes] of the note whose top the list should scroll to on
/// open, or null when the list should keep its default (newest-at-bottom)
/// position.
///
/// - single note          -> 0
/// - multiple, has unread  -> the oldest unread note (min `sourceCreatedAt`)
/// - multiple, none unread -> null
///
/// Order-independent: the target is found by timestamp, so it does not
/// matter whether [notes] is newest- or oldest-first.
int? initialScrollTargetIndex(
  List<Note> notes, {
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (notes.isEmpty) return null;
  if (notes.length == 1) return 0;
  int? targetIndex;
  DateTime? targetTime;
  for (var i = 0; i < notes.length; i++) {
    if (!noteIsUnread(notes[i], threadUnread: threadUnread, readAt: readAt)) {
      continue;
    }
    final t = notes[i].sourceCreatedAt;
    if (targetTime == null || t.isBefore(targetTime)) {
      targetTime = t;
      targetIndex = i;
    }
  }
  return targetIndex;
}
