import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plot/analytics/tracker.dart';

import 'package:plot/store/store.dart';

/// Global, single-slot "undo send" controller.
///
/// On send, the note (and, for a brand-new thread, the thread) is already saved
/// as a normal NON-draft row, so it appears in lists / feeds / search and
/// renders seamlessly in place — only its footer shows `SENDING` instead of the
/// author/timestamp during the window. The row's remote PUSH is held (via
/// [Store.pushHeldNoteIds] / [Store.pushHeldThreadIds]) for [window] so others
/// don't see it until it commits.
///
/// - [commit] releases the hold and pushes (the note depends on its thread, so
///   the thread + its links push first when needed).
/// - [undo] hides the never-pushed note (back to draft + archived, so it leaves
///   the list and can never sync), returns a brand-new thread to draft (→ the
///   drafts list), and hands the note back so its content can be restored.
/// - [flush] commits immediately on app-close / sign-out.
///
/// Only one send is in flight at a time: [start] commits any prior pending send.
class PendingSend extends ChangeNotifier {
  PendingSend._();
  static final PendingSend instance = PendingSend._();

  static const Duration window = Duration(seconds: 5);

  NoteId? _noteId;
  ThreadId? _threadId;
  bool _promotedThreadFromDraft = false;
  Timer? _timer;

  bool get isPending => _noteId != null;
  NoteId? get pendingNoteId => _noteId;
  ThreadId? get pendingThreadId => _threadId;
  bool get promotedThreadFromDraft => _promotedThreadFromDraft;

  /// Begins a [window]-second undo window for an already-saved (non-draft,
  /// unpushed) note. Set [promotedThreadFromDraft] when this send promoted a
  /// brand-new / draft thread out of draft (its push is held too, and undo
  /// returns it to draft). Commits any prior pending send first.
  void start({
    required NoteId noteId,
    required ThreadId threadId,
    bool promotedThreadFromDraft = false,
  }) {
    if (isPending) unawaited(commit());
    _noteId = noteId;
    _threadId = threadId;
    _promotedThreadFromDraft = promotedThreadFromDraft;
    Store.pushHeldNoteIds.add(_hex(noteId.toBytes()));
    if (promotedThreadFromDraft) {
      Store.pushHeldThreadIds.add(_hex(threadId.toBytes()));
    }
    _timer?.cancel();
    _timer = Timer(window, () => unawaited(commit()));
    notifyListeners();
  }

  /// Releases the push hold and pushes the (already-saved) note + thread.
  /// Store-level and context-free so it is safe from app-close / sign-out.
  Future<void> commit() async {
    if (_noteId == null) return;
    _release();
    notifyListeners();
    try {
      await SyncOrchestrator.instance.push(SyncOrchestrator.note);
    } catch (e, t) {
      try {
        await Tracker.captureException(e, t);
      } catch (_) {
        // Never let error-reporting failure suppress the original error path.
      }
    }
  }

  /// Cancels the send: hides the never-pushed note (draft + archived, so it
  /// leaves the list and never syncs), returns a brand-new thread to draft, and
  /// returns the note so its content can be restored into the editor.
  Future<Note?> undo() async {
    final noteId = _noteId;
    final threadId = _threadId;
    final demote = _promotedThreadFromDraft;
    if (noteId == null) return null;
    _release();
    notifyListeners();
    if (!Store.isAvailable) return null;
    try {
      final note = await Note.get(noteId);
      if (note != null) {
        // draft = true → excluded from the notes list AND the push claim;
        // archived → never resurfaces as a resumable draft. Local-only.
        await note
            .copyWith(draft: true, archivedAt: Value(DateTime.now()))
            .save(pushToRemote: false);
      }
      if (demote && threadId != null) {
        final thread = await Thread.getOne(threadId);
        // Back to draft → leaves the feed, shows in the drafts list if
        // abandoned. Draft threads are excluded from the push claim.
        await thread.copyWith(draft: true).save();
      }
      return note;
    } catch (e, t) {
      try {
        await Tracker.captureException(e, t);
      } catch (_) {
        // Never let error-reporting failure suppress the undo result.
      }
      return null;
    }
  }

  /// Commit immediately if something is pending (app-close / sign-out).
  Future<void> flush() async {
    if (isPending) await commit();
  }

  void _release() {
    final noteId = _noteId;
    final threadId = _threadId;
    if (noteId != null) Store.pushHeldNoteIds.remove(_hex(noteId.toBytes()));
    if (_promotedThreadFromDraft && threadId != null) {
      Store.pushHeldThreadIds.remove(_hex(threadId.toBytes()));
    }
    _timer?.cancel();
    _timer = null;
    _noteId = null;
    _threadId = null;
    _promotedThreadFromDraft = false;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
