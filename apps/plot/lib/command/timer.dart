import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/shortcut.dart';

import 'base.dart';

/// Shared keyboard shortcuts for the timer family. Surfaced in button
/// tooltips, the Timer menu, and the priority command scope so users can
/// discover them without memorizing.
///
/// Start and Pause share [timerToggleShortcut] (Cmd/Ctrl+Shift+Space) —
/// the priority command scope binds whichever is currently enabled, and
/// both commands carry the shortcut for display purposes so the tooltip
/// is consistent across the inactive/active swap on the header pill.
final SingleActivator timerToggleShortcut =
    platformSingleActivator(LogicalKeyboardKey.space, shift: true);
final SingleActivator timerEndShortcut =
    platformSingleActivator(LogicalKeyboardKey.period, shift: true);
final SingleActivator timerAddShortcut =
    platformSingleActivator(LogicalKeyboardKey.equal, shift: true);
final SingleActivator timerRemoveShortcut =
    platformSingleActivator(LogicalKeyboardKey.minus, shift: true);

/// Timer commands appended to the priority command group so shortcuts
/// are discoverable alongside the rest of the priority's actions. The
/// priority page mounts the priority group (which includes these) in
/// its [CommandScope] so the shortcuts work anywhere on the page, not
/// just when the header pill has focus.
List<Command> timerCommands(NowState state) {
  if (state is! NowLoaded) return const [];
  if (state.context == null) return const [];
  final inactive = state.pomodoroState == PomodoroState.inactive;
  return [
    if (inactive) StartTimer() else StopTimer(),
    if (!inactive) ...[EndTimer(), AddTime(), RemoveTime()],
  ];
}

/// Start a pomodoro session on the currently-focused priority. The
/// planned duration honors any inactive-state preview the user staged
/// via [AddTime] / [RemoveTime]; otherwise it falls back through the
/// priority's `priority_block.duration`, the distraction default, or
/// [kDefaultPomodoro]. See [NowBloc.startSession] for the full rules.
class StartTimer extends Command {
  StartTimer()
    : super(
        title: 'Start focus',
        icon: FontAwesomeIcons.play,
        eventObject: EventObject.priority,
        eventAction: EventAction.started,
        shortcut: timerToggleShortcut,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    if (state is! NowLoaded) return false;
    if (state.context == null) return false;
    return state.pomodoroState == PomodoroState.inactive;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().startSession();
    return const CommandDone();
  }
}

/// Pause the active pomodoro session, preserving the time remaining so
/// the user can resume the same countdown later via [StartTimer].
class StopTimer extends Command {
  StopTimer()
    : super(
        title: 'Pause focus',
        icon: FontAwesomeIcons.pause,
        eventObject: EventObject.priority,
        eventAction: EventAction.finished,
        shortcut: timerToggleShortcut,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    if (state is! NowLoaded) return false;
    return state.pomodoroState != PomodoroState.inactive;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().stopSession();
    return const CommandDone();
  }
}

/// Fully end the active pomodoro session. Unlike [StopTimer] (which
/// pauses with the remaining time preserved for resume), pressing this
/// truncates the planned window to what actually ran — the next
/// [StartTimer] opens a fresh pomodoro instead of picking up where this
/// one left off.
class EndTimer extends Command {
  EndTimer()
    : super(
        title: 'Stop focus',
        icon: FontAwesomeIcons.stop,
        eventObject: EventObject.priority,
        eventAction: EventAction.finished,
        shortcut: timerEndShortcut,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    if (state is! NowLoaded) return false;
    return state.pomodoroState != PomodoroState.inactive;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().endSession();
    return const CommandDone();
  }
}

/// Bump the pomodoro UP to the next 15-minute boundary of remaining
/// time. Works in any state — when inactive, it advances the preview
/// duration the pill shows; when active (or in grace), it lengthens
/// the running session so its end aligns with the next 15m mark.
class AddTime extends Command {
  AddTime()
    : super(
        title: 'Add time',
        icon: FontAwesomeIcons.plus,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
        shortcut: timerAddShortcut,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    return state is NowLoaded && state.context != null;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().bumpPomodoroToNext15();
    return const CommandDone();
  }
}

/// Shrink the pomodoro by 15 minutes. When less than 15m of remaining
/// time is left, the timer instead snaps to [kMinPomodoro] (5m) so the
/// `−` press still produces a meaningful result without overshooting
/// the floor.
class RemoveTime extends Command {
  RemoveTime()
    : super(
        title: 'Remove time',
        icon: FontAwesomeIcons.minus,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
        shortcut: timerRemoveShortcut,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    if (state is! NowLoaded) return false;
    final ctx = state.context;
    if (ctx == null) return false;
    final session = state.session;
    final isActiveForCtx =
        session != null &&
        session.at.isNow() &&
        session.source == 'active' &&
        session.priority?.id == ctx.id &&
        session.pomodoroAt != null &&
        session.pomodoro != null;
    if (isActiveForCtx) {
      final remaining = session.pomodoroAt!
          .add(session.pomodoro!)
          .difference(Time.now());
      return remaining > kMinPomodoro;
    }
    final base =
        state.previewPomodoro ?? state.pendingFor(ctx) ?? kDefaultPomodoro;
    return base > kMinPomodoro;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().decreasePomodoro();
    return const CommandDone();
  }
}
