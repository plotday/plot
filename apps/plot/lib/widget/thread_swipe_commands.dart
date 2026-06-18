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
/// The model is **right = act on it, left = file it**. Right keeps the
/// swipe-right-to-complete convention for `Done` and pairs it with the
/// engage action on the long zone; left is always `Move` (short) then the
/// menu (long), so filing and overflow sit in one consistent place.
///
/// - Right short — `Done` (marks read + bumps into Done) whenever there is
///   anything to clear (it's a to-do, or it has unread content). In the Done
///   list (already read, not a to-do) there is nothing to finish, so it
///   becomes `To do` to re-activate the thread instead.
/// - Right long — the engage action. `To do` (pull it into Doing) when it
///   isn't a to-do yet; `Do later` (re-pick the day) when it already is, or
///   when it's a finished thread in the Done list.
/// - Left short — `Move` to another priority. Always available.
/// - Left long — the menu. Always available.
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
  // read. A thread with nothing to clear (read, not a to-do) is in the Done
  // list, where the right swipe re-engages it rather than finishing it again.
  final hasSomethingToClear = thread.todo || thread.unread;

  return (
    rightShort: hasSomethingToClear
        ? FinishThread(thread, bump: bump, onBeforeRun: finishOnBeforeRun)
        : ToggleThreadActive(thread),
    rightLong: thread.todo || !hasSomethingToClear
        ? PickScheduleThread(thread)
        : ToggleThreadActive(thread),
    leftShort: MoveThreadToPriority(thread),
    leftLong: ShowThreadCommands(thread),
  );
}
