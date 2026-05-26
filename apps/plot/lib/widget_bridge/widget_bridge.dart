import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:plot/state/now.dart';
import 'package:plot/state/user.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/time.dart';

import 'widget_bridge_channel.dart';
import 'widget_data.dart';

/// Side-effect listener that watches the user/now blocs and pushes
/// a fresh [WidgetState] to the native widget host whenever the
/// signed-in user, context priority, or active timer changes.
///
/// The bridge intentionally does not own any UI — it only translates
/// app state into the data widgets read on their own refresh
/// timeline. Callers attach it once at app startup (see
/// `RootProvider`) and dispose it on tear-down.
class WidgetBridge {
  WidgetBridge({required UserBloc userBloc, required NowBloc nowBloc})
    // ignore: prefer_initializing_formals
    : _userBloc = userBloc,
      // ignore: prefer_initializing_formals
      _nowBloc = nowBloc;

  final UserBloc _userBloc;
  final NowBloc _nowBloc;

  StreamSubscription<UserState>? _userSub;
  StreamSubscription<NowState>? _nowSub;
  Timer? _debounce;
  WidgetState _last = WidgetState.signedOut();
  bool _started = false;

  /// Begin streaming state to the native host. Safe to call
  /// multiple times; subsequent calls are no-ops.
  void start() {
    if (_started || !WidgetBridgeChannel.isSupportedPlatform) return;
    _started = true;
    WidgetBridgeChannel.instance.attach();
    WidgetBridgeChannel.instance.setHandler(_handleAction);

    _userSub = _userBloc.stream.listen((_) => _scheduleSync());
    _nowSub = _nowBloc.stream.listen((_) => _scheduleSync());
    _scheduleSync(immediate: true);
  }

  /// Stop streaming and clear any pending debounce.
  Future<void> stop() async {
    _started = false;
    _debounce?.cancel();
    _debounce = null;
    await _userSub?.cancel();
    await _nowSub?.cancel();
    _userSub = null;
    _nowSub = null;
    WidgetBridgeChannel.instance.setHandler(null);
  }

  void _scheduleSync({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      unawaited(_sync());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    final next = _snapshot();
    if (next == _last) return;
    _last = next;
    debugPrint(
      '[widget-bridge] state '
      'signedIn=${next.isSignedIn} '
      'priority=${next.currentPriorityId ?? '-'} '
      'timer=${next.timerState}${next.timerSource != null ? '/${next.timerSource}' : ''}',
    );
    await WidgetBridgeChannel.instance.writeState(next);
    await WidgetBridgeChannel.instance.reloadAll();
  }

  WidgetState _snapshot() {
    final userState = _userBloc.state;
    if (userState is! UserReady) {
      return WidgetState.signedOut();
    }
    final user = userState.user;
    final nowState = _nowBloc.state;
    if (nowState is! NowLoaded) {
      return WidgetState(isSignedIn: true, userId: user.id);
    }
    final priority = nowState.priority;
    final ctx = nowState.context;
    final hasContext = ctx != null;

    String? timerEndsAtIso;
    String timerState = 'inactive';
    String? timerSource;

    final session = nowState.session;
    final isActiveSession =
        session != null &&
        session.at.isNow() &&
        session.source == 'active' &&
        session.priority?.id == ctx?.id &&
        session.pomodoroAt != null &&
        session.pomodoro != null;
    if (isActiveSession) {
      timerSource = 'session';
      timerState = 'running';
      timerEndsAtIso = session.pomodoroAt!
          .add(session.pomodoro!)
          .toUtc()
          .toIso8601String();
    } else {
      final event = nowState.inProgressEventForContext;
      if (event != null && event.at?.end != null) {
        timerSource = 'event';
        timerState = 'running';
        timerEndsAtIso = event.at!.end!.toUtc().toIso8601String();
      }
    }

    final isSessionRunning = timerSource == 'session';
    final canStart =
        hasContext && nowState.pomodoroState == PomodoroState.inactive;
    final canPause = isSessionRunning;
    final canStop = isSessionRunning;

    final canAddTime = hasContext && timerSource != 'event';
    final canRemoveTime = hasContext && _canRemoveTime(nowState);

    // The first event in `nowState.next` is the earliest future event
    // across all priorities — the natural "what's coming up" anchor for
    // the menu bar / tray banner. Native code decides when to surface
    // it (currently: countdown ≤ 10m) so the banner ticks down without
    // needing another state push.
    String? nextEventTitle;
    String? nextEventStartIso;
    final upcoming = nowState.next;
    if (upcoming.isNotEmpty) {
      final event = upcoming.first;
      final start = event.at?.start;
      if (start != null) {
        nextEventTitle = event.displayTitle;
        nextEventStartIso = start.toUtc().toIso8601String();
      }
    }

    return WidgetState(
      isSignedIn: true,
      userId: user.id,
      currentPriorityId: priority.id.toString(),
      currentPriorityTitle: priority.title,
      currentEventTitle: nowState.currentEvent?.displayTitle,
      timerState: timerState,
      timerSource: timerSource,
      timerEndsAtIso: timerEndsAtIso,
      nextEventTitle: nextEventTitle,
      nextEventStartIso: nextEventStartIso,
      canStart: canStart,
      canPause: canPause,
      canStop: canStop,
      canAddTime: canAddTime,
      canRemoveTime: canRemoveTime,
    );
  }

  /// Mirrors `RemoveTime.enabled` in `lib/command/timer.dart` — we
  /// want the menu's grey-out logic to match the in-app `−` button
  /// exactly so users get the same affordance everywhere.
  bool _canRemoveTime(NowLoaded state) {
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

  Future<Object?> _handleAction(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case widgetActionStartTimer:
        await _nowBloc.startSession();
        return null;
      case widgetActionPauseTimer:
        await _nowBloc.stopSession();
        return null;
      case widgetActionStopTimer:
        await _nowBloc.endSession();
        return null;
      case widgetActionAddTime:
        await _nowBloc.bumpPomodoroToNext15();
        return null;
      case widgetActionRemoveTime:
        await _nowBloc.decreasePomodoro();
        return null;
    }
    return null;
  }
}
