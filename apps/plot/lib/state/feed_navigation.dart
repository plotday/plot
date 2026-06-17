import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Navigation decision after an explicit state change on the open thread.
///
/// [open]: the thread to open, or null for no navigation.
/// [stay]: the changed thread should stay open — it renders in Done
/// (rule 3), isn't in the list, or the feed is flat. Distinguishes "stay
/// put" from "nothing left to open" ([open] null, [stay] false), which
/// lets Done's caller fall back to the compose page.
typedef StateChangeNav = ({Thread? open, bool stay});

/// Decide which thread to open after the user changes the state of
/// [changedId] while it is the open thread, per the reposition spec:
///
/// - The decision is computed against the PRE-change [items] (call this
///   before applying the optimistic update).
/// - In single panel ([multiPanel] false) the changed thread always stays
///   open. The user explicitly drilled into the thread (it is a pushed
///   full-screen route, not a row beside a visible list), so auto-advancing
///   to an unrelated thread is disorienting — they pop back to the list when
///   ready. The advance-through-the-list flow only makes sense in multi
///   panel, where the list stays visible alongside the open thread.
/// - Threads rendered in Active (Doing, including the unread cluster) or
///   Scheduled open the next thread below, across sections.
/// - Exception: when the changed thread is the last one before the Done
///   section and there are threads above it, the previous thread above is
///   opened instead (supports working bottom-up).
/// - In the Done section the changed thread stays open.
StateChangeNav nextThreadAfterStateChange(
  List<AgendaItem> items,
  ThreadId changedId, {
  required bool multiPanel,
}) {
  if (!multiPanel) return (open: null, stay: true);

  // Walk the feed, tracking each thread row's section from the
  // marker-encoded headers above it.
  ActivitySection? section;
  final rows = <({Thread thread, ActivitySection? section})>[];
  var changedIndex = -1;
  for (final item in items) {
    item.when<void>(
      header: (h) {
        final marker = h.text == null
            ? null
            : ActivitySectionMarker.tryDecode(h.text!);
        if (marker != null) section = marker.section;
      },
      activity: (a) {
        if (a.thread.id == changedId && changedIndex == -1) {
          changedIndex = rows.length;
        }
        rows.add((thread: a.thread, section: section));
      },
    );
  }

  if (changedIndex == -1) return (open: null, stay: true);
  if (rows[changedIndex].section == ActivitySection.activity) {
    return (open: null, stay: true);
  }

  final below = changedIndex + 1 < rows.length ? rows[changedIndex + 1] : null;
  final above = changedIndex > 0 ? rows[changedIndex - 1] : null;

  if (below != null && below.section != ActivitySection.activity) {
    return (open: below.thread, stay: false);
  }
  if (below != null) {
    // The changed thread was the last one before Done: prefer the thread
    // above; fall through to the first Done thread when nothing is above.
    return (open: (above ?? below).thread, stay: false);
  }
  return (open: above?.thread, stay: false);
}
