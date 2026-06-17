import 'package:flutter/widgets.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';

/// The four swipe-slot commands for a thread row, one per zone.
typedef ThreadSwipeCommands = ({
  Command? rightShort,
  Command? rightLong,
  Command? leftShort,
  Command? leftLong,
});

/// Resolves the swipe-to-action commands for [thread].
///
/// The model is **left = engage, right = clear**:
///
/// - Left short — `To do` (pull it into Doing, marks read) when it isn't a
///   to-do yet; `Do later` (re-pick the day) when it already is.
/// - Left long — `Move` to another priority. Always available.
/// - Right short — `Done` whenever there is anything to clear (it's a to-do,
///   or it has unread content); otherwise jump straight to the menu, so a
///   fully-cleared thread (read, not a task) still has a useful right swipe.
/// - Right long — the menu, but only when right-short isn't already the menu,
///   so the same command never shows at both the short and long thresholds.
///
/// All slots are disabled when [isOutsidePriority] (the thread is shown
/// outside its own priority, e.g. in search or a cross-priority view).
ThreadSwipeCommands resolveThreadSwipeCommands(
  Thread thread, {
  required bool isOutsidePriority,
  required bool bump,
  required Future<void> Function(BuildContext context)? finishOnBeforeRun,
}) {
  if (isOutsidePriority) {
    return (rightShort: null, rightLong: null, leftShort: null, leftLong: null);
  }

  // Anything to clear: an active to-do to finish, or unread content to mark
  // read. Both resolve to a full finish (mark read + bump into Done).
  final hasSomethingToClear = thread.todo || thread.unread;

  return (
    rightShort: hasSomethingToClear
        ? FinishThread(thread, bump: bump, onBeforeRun: finishOnBeforeRun)
        : ShowThreadCommands(thread),
    rightLong: hasSomethingToClear ? ShowThreadCommands(thread) : null,
    leftShort: thread.todo
        ? PickScheduleThread(thread)
        : ToggleThreadActive(thread),
    leftLong: MoveThreadToPriority(thread),
  );
}
