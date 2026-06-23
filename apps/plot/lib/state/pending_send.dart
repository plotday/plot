import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plot/analytics/tracker.dart';

import 'package:plot/store/store.dart';

/// Global, single-slot "undo send" controller.
///
/// When a user sends a note we do NOT publish/push it immediately. Instead the
/// publish-ready note (and, for a brand-new thread, the promote-ready thread)
/// is held here in memory and a [window] timer is armed. The thread view
/// renders the held note with a `SENDING` footer. When the timer fires — or the
/// app closes / signs out — [commit] saves and pushes it. [undo] drops it and
/// hands the note back so its content can be restored into the editor.
///
/// Only one send is ever in flight: [start] commits any prior pending send
/// first.
class PendingSend extends ChangeNotifier {
  PendingSend._();
  static final PendingSend instance = PendingSend._();

  static const Duration window = Duration(seconds: 5);

  Note? _note;
  Thread? _newThread;
  Timer? _timer;

  bool get isPending => _note != null;
  Note? get pendingNote => _note;
  ThreadId? get pendingThreadId => _note?.threadId;

  /// Registers a new pending send. [note] must be the publish version
  /// (`draft == false`). [newThread] is the promote version (`draft == false`)
  /// for a new-thread send, or null when replying to an existing thread.
  void start({required Note note, Thread? newThread}) {
    if (isPending) {
      // One at a time: finalize the prior send before starting a new one.
      unawaited(commit());
    }
    _note = note;
    _newThread = newThread;
    _timer?.cancel();
    _timer = Timer(window, () => unawaited(commit()));
    notifyListeners();
  }

  /// Publishes the held note (and promotes the held thread), then clears.
  /// Store-level and context-free so it is safe from app-close / sign-out.
  Future<void> commit() async {
    final note = _note;
    final newThread = _newThread;
    if (note == null) return;
    _clear();
    notifyListeners();
    try {
      if (newThread != null) {
        // draft == false → promotes the thread out of draft and pushes it.
        await newThread.save();
      }
      // draft == false → publishes the note and pushes it.
      await note.save();
    } catch (e, t) {
      // A failed commit must not strand the app; surface for diagnosis.
      try {
        await Tracker.captureException(e, t);
      } catch (_) {
        // Never let error-reporting failure suppress the original error path.
      }
    }
  }

  /// Cancels the pending send and returns the note so the caller can move its
  /// content back into the NoteEditor. Performs no DB writes — nothing was
  /// persisted as published during the window.
  Future<Note?> undo() async {
    final note = _note;
    _clear();
    notifyListeners();
    return note;
  }

  /// Commit immediately if something is pending (app-close / sign-out).
  Future<void> flush() async {
    if (isPending) await commit();
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _note = null;
    _newThread = null;
  }
}
