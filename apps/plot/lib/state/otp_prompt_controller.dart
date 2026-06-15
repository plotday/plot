import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'package:plot/store/store.dart';

const kCtaWindow = Duration(minutes: 5);

class OtpPrompt {
  OtpPrompt(this.note);
  final Note note;
  Cta get cta => note.cta!;
}

class OtpPromptController {
  /// Creates a controller with no Drift subscription. Call [attach] once a
  /// [Store] is available, and [detach] on sign-out. [AppShell] drives this
  /// from [UserBloc] auth state rather than reading `Store.get` at mount: it is
  /// the persistent root shell and mounts before sign-in (hosting SignInRoute),
  /// when no Store is registered — touching `Store.get` then throws
  /// `The type "Store" is not defined!`.
  OtpPromptController();

  /// Test constructor — no Drift subscription; drive via [onNotes].
  factory OtpPromptController.forTest() => OtpPromptController();

  final ValueNotifier<OtpPrompt?> current = ValueNotifier(null);
  final Set<String> _dismissed = {};
  StreamSubscription<void>? _sub;
  Timer? _expiry;

  /// Subscribe to [store]'s recent cta-bearing notes. Idempotent: cancels any
  /// existing subscription first, so it is safe to call again after a
  /// re-sign-in (the store instance changes on each [Store.start]).
  void attach(Store store) {
    _sub?.cancel();
    final n = store.notes;
    // Watch recent non-archived notes with a non-null cta, newest first,
    // bounded to 10.
    _sub = (store.select(n)
          ..where((t) => t.cta.isNotNull() & t.archivedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.sourceCreatedAt)])
          ..limit(10))
        .watch()
        .listen((rows) => onNotes(rows.map(_noteFromRow).toList()));
  }

  /// Drop the store subscription and hide any visible prompt. Called on
  /// sign-out, before the Store is torn down, so the Drift stream doesn't
  /// outlive its database.
  void detach() {
    _sub?.cancel();
    _sub = null;
    _expiry?.cancel();
    _expiry = null;
    current.value = null;
  }

  static Note _noteFromRow(NoteRow r) => Note(
        id: r.id,
        threadId: r.threadId,
        authorId: r.authorId,
        draft: r.draft,
        accessContacts: r.accessContacts,
        accessGroups: r.accessGroups,
        content: r.content,
        actions: r.actions,
        cta: r.cta,
        mentions: r.mentions,
        reNoteId: r.reNoteId,
        createdAt: r.createdAt,
        sourceCreatedAt: r.sourceCreatedAt,
        updatedAt: r.updatedAt,
        archivedAt: r.archivedAt,
        mergedFromThreadId: r.mergedFromThreadId,
        pending: r.pending,
      );

  /// Evaluate candidate notes; pick the latest in-window, non-dismissed cta.
  void onNotes(List<Note> notes, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final eligible = notes
        .where((n) => n.cta != null)
        .where((n) => !_dismissed.contains(n.id.toString()))
        .where((n) => t.difference(n.sourceCreatedAt) < kCtaWindow)
        .toList()
      ..sort((a, b) => b.sourceCreatedAt.compareTo(a.sourceCreatedAt));
    current.value = eligible.isEmpty ? null : OtpPrompt(eligible.first);
    _armExpiry(t);
  }

  void _armExpiry(DateTime now) {
    _expiry?.cancel();
    final prompt = current.value;
    if (prompt == null) return;
    final remaining = kCtaWindow - now.difference(prompt.note.sourceCreatedAt);
    if (remaining > Duration.zero) {
      _expiry = Timer(remaining, () {
        final p = current.value;
        if (p != null &&
            DateTime.now().difference(p.note.sourceCreatedAt) >= kCtaWindow) {
          current.value = null;
        }
      });
    }
  }

  void dismiss() {
    final n = current.value?.note;
    if (n != null) _dismissed.add(n.id.toString());
    current.value = null;
    _expiry?.cancel();
  }

  void dispose() {
    detach();
    current.dispose();
  }
}
