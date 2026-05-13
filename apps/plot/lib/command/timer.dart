import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';

import 'base.dart';

/// Start a pomodoro session on the currently-focused priority. The
/// planned duration honors any inactive-state preview the user staged
/// via [AddTime] / [RemoveTime]; otherwise it falls back through the
/// priority's `priority_block.duration`, the distraction default, or
/// [kDefaultPomodoro]. See [NowBloc.startSession] for the full rules.
class StartTimer extends Command {
  StartTimer()
    : super(
        title: 'Start timer',
        icon: FontAwesomeIcons.play,
        eventObject: EventObject.priority,
        eventAction: EventAction.started,
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
        title: 'Pause timer',
        icon: FontAwesomeIcons.pause,
        eventObject: EventObject.priority,
        eventAction: EventAction.finished,
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
        title: 'Remove 15 minutes',
        icon: FontAwesomeIcons.minus,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  bool enabled(BuildContext context) {
    final state = context.read<NowBloc>().state;
    if (state is! NowLoaded) return false;
    final ctx = state.context;
    if (ctx == null) return false;
    final session = state.session;
    final isActiveForCtx = session != null
        && session.at.isNow()
        && session.source == 'active'
        && session.priority?.id == ctx.id
        && session.pomodoroAt != null
        && session.pomodoro != null;
    if (isActiveForCtx) {
      final remaining = session.pomodoroAt!
          .add(session.pomodoro!)
          .difference(Time.now());
      return remaining > kMinPomodoro;
    }
    final base = state.previewPomodoro
        ?? state.pendingFor(ctx)
        ?? kDefaultPomodoro;
    return base > kMinPomodoro;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.read<NowBloc>().decreasePomodoro();
    return const CommandDone();
  }
}
