import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/store/store.dart';

part 'now_state.dart';

class NowBloc extends Cubit<NowState> {
  NowBloc() : super(const NowLoading());

  bool get loading => super.state is NowLoading;
  NowLoaded get loadedState => super.state as NowLoaded;

  StreamSubscription<void>? _subscription;
  Timer? _trackTick;

  @override
  Future<void> close() {
    stop();
    return super.close();
  }

  Future<void> start() {
    final completer = Completer<void>();
    _subscription =
        Rx.combineLatest6(
          Priority.watchDefault(),
          ScheduledDay.watchToday(),
          Session.watchCurrent(),
          Priority.watch(archived: false),
          streamPriorityBlocksGroupedByPriority(),
          UserSettingsEntity.watch(),
          (priority, day, session, priorities, blocksByPriority, settings) {
            final prior = state is NowLoaded ? (state as NowLoaded) : null;
            return NowLoaded(
              defaultPriority: priority,
              day: day,
              session: session,
              priorities: priorities,
              priorityBlocksByPriority: blocksByPriority,
              trackingPausedAt: settings?.trackingPausedAt,
              context: prior?.context,
              currentEvent: prior?.currentEvent,
              previewPomodoro: prior?.previewPomodoro,
            );
          },
        ).listen(
          (state) {
            emit(state);
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object error, StackTrace? stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        );
    // Maintenance tick: refresh the active session's `end` so
    // `at.isNow()` stays true, and auto-stop when the 5-minute grace
    // expires. No auto-start — sessions begin only via [startSession].
    _trackTick = Timer.periodic(const Duration(minutes: 1), (_) => _onTrackTick());
    scheduleMicrotask(_onTrackTick);
    return completer.future;
  }

  void stop() {
    _subscription?.cancel();
    _trackTick?.cancel();
    _trackTick = null;
    // Reset state to prevent stale data from persisting across user sessions
    emit(const NowLoading());
  }

  /// Maintenance tick for the active pomodoro session. Does NOT start
  /// sessions — start is exclusively user-driven via [startSession].
  ///
  /// Two responsibilities:
  ///   1. While the pomodoro is within its `pomodoroAt + pomodoro + 5m`
  ///      window, keep the row's `end` bumped to `Time.now() + 3m` so
  ///      `Session.watchCurrent` keeps reporting it (otherwise its
  ///      `at.isNow()` check would fail and the pill would drop back to
  ///      inactive).
  ///   2. Once the grace period elapses, auto-close the session via
  ///      [_closeActiveSessionAndWriteBack] (which also writes the
  ///      consumed time back to `priority_block`).
  Future<void> _onTrackTick() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final session = s.session;
    if (session == null) return;
    if (session.source != 'active') return;
    if (session.pomodoroAt == null || session.pomodoro == null) return;

    final now = Time.now();
    final graceEnd = session.pomodoroAt!
        .add(session.pomodoro!)
        .add(kPomodoroGrace);
    if (!now.isBefore(graceEnd)) {
      await _closeActiveSessionAndWriteBack(session);
      return;
    }
    if (session.at.end.isBefore(now.add(const Duration(minutes: 1)))) {
      // Extend forward so `at.isNow()` keeps holding through the next
      // tick. Mirrors the 3-minute lookahead that `setFocus` originally
      // wrote when sessions were auto-started.
      await Session.fromStore(
        session.copyWith(end: now.add(const Duration(minutes: 3))),
      ).save();
    }
  }

  Future<void> _closeActiveSessionAndWriteBack(Session existing) async {
    final now = Time.now();
    final priority = existing.priority;

    // Preserve the time remaining in the planned pomodoro window so the
    // user can pause and resume without losing the countdown. When the
    // session has no pomodoro planned (e.g. an 'event' source row),
    // fall back to the wall-clock write-back against priority_blocks.
    Duration? newPending;
    if (existing.pomodoroAt != null && existing.pomodoro != null) {
      final end = existing.pomodoroAt!.add(existing.pomodoro!);
      final remaining = end.difference(now);
      newPending = remaining > Duration.zero ? remaining : null;
    } else if (priority != null) {
      final rows =
          loadedState.priorityBlocksByPriority[priority.id] ?? const [];
      final startPending = effectivePriorityDurationAt(
        moment: existing.at.start,
        blocksForPriority: rows,
      );
      if (startPending != null) {
        final consumed = now.difference(existing.at.start);
        final remaining = startPending - consumed;
        newPending = remaining > Duration.zero ? remaining : null;
      }
    }

    // Write the priority_block update FIRST so `pendingFor` already
    // returns the preserved remaining by the time the session-save
    // emits and the pill switches to its inactive state. Reversing
    // the order causes a one-frame flash of the old pending value.
    if (priority != null) {
      await PriorityBlock.setPendingDuration(priority.id, newPending);
    }

    // Pin the session's `end` to now so the row no longer satisfies
    // `at.isNow()` — that lets `Session.watchCurrent` clear and prevents
    // the next tick from accidentally extending it.
    final closed = Session.fromStore(existing.copyWith(end: now));
    await closed.save();
  }

  /// Live remaining-duration stream for the agenda block header. Combines
  /// the priority_block resolver with a 60-second wall-clock tick so the
  /// displayed value decrements smoothly while an active session is open.
  /// Emits null when the priority has no pending or has reached zero.
  static Stream<Duration?> watchPendingDuration(PriorityId priorityId) {
    // Rebuild on every priority-blocks change AND every minute boundary.
    return Rx.combineLatest3(
      streamPriorityBlocksGroupedByPriority(),
      Session.watchCurrent(),
      Stream<void>.periodic(const Duration(minutes: 1), (_) {}).startWith(null),
      (blocksByPriority, currentSession, _) {
        final rows = blocksByPriority[priorityId] ?? const [];
        final now = Time.now();
        final base = effectivePriorityDurationAt(
          moment: now,
          blocksForPriority: rows,
        );
        if (base == null) return null;
        final isActiveForThisPriority = currentSession != null
            && currentSession.priority?.id == priorityId
            && currentSession.at.isNow();
        if (!isActiveForThisPriority) return base;
        // Deduct elapsed time since the LATER of (session start) and
        // (most recent priority_block's effective_at). If the user
        // manually re-set pending mid-session, the new block's
        // effective_at is after session.start; deducting from session.start
        // would double-count time the user just reset away.
        final effectiveFrom =
            _latestEffectiveAt(rows, asOf: now) ?? currentSession.at.start;
        final deductFrom = effectiveFrom.isAfter(currentSession.at.start)
            ? effectiveFrom
            : currentSession.at.start;
        final elapsed = now.difference(deductFrom);
        if (elapsed <= Duration.zero) return base;
        final remaining = base - elapsed;
        return remaining > Duration.zero ? remaining : null;
      },
    );
  }

  /// Most-recent non-archived priority_block effective_at <= [asOf], or
  /// null if no row qualifies. Mirrors the search inside
  /// [effectivePriorityDurationAt] but returns the moment rather than the
  /// duration.
  static DateTime? _latestEffectiveAt(
    Iterable<PriorityBlockRow> rows, {
    required DateTime asOf,
  }) {
    DateTime? best;
    for (final r in rows) {
      if (r.archivedAt != null) continue;
      if (r.effectiveAt.isAfter(asOf)) continue;
      if (best == null || r.effectiveAt.isAfter(best)) {
        best = r.effectiveAt;
      }
    }
    return best;
  }

  /// Context is the priority being displayed, which may
  /// be more general than the focus.
  ///
  /// When a session is already running on the previously-displayed
  /// priority, this method closes it and immediately starts a new
  /// pomodoro on the new context (distraction-handoff per the spec:
  /// "stopping counting time on the previous priority and start counting
  /// time against the new priority"). When no session is running, this
  /// is a pure view change — nothing auto-starts.
  void setContext(Priority? priority) async {
    final prior = loadedState;
    if (prior.context?.id == priority?.id) return;
    // Sticky-until-navigated-away: clear currentEvent whenever the
    // displayed priority changes to one that doesn't own the event.
    final currentEvent = prior.currentEvent;
    final keepEvent =
        currentEvent != null && currentEvent.priority.id == priority?.id;
    emit(prior.copyWith(
      context: priority,
      currentEvent: keepEvent ? currentEvent : null,
      // Staged duration is per-priority — drop it whenever the user
      // navigates to a different priority.
      previewPomodoro: null,
    ));

    // If a session was running on the prior context, chain start →
    // stop on it and a fresh start on the new context. `startSession`
    // closes the previously-active session, applies the resume-within-
    // time-block rule, and falls back to `kDistractionPomodoro` since
    // there's still an active session at the moment it's called.
    final wasActive = prior.session != null
        && prior.session!.at.isNow()
        && prior.session!.source == 'active'
        && prior.session!.pomodoroAt != null;
    if (wasActive && priority != null) {
      await startSession();
    }
  }

  /// Set the agenda's currently-selected event. Pass null to clear.
  /// Also pulls the context to the event's priority so PriorityPage
  /// displays the correct workspace.
  void setCurrentEvent(Thread? event) {
    if (loadedState.currentEvent?.id == event?.id &&
        loadedState.currentEvent?.occurrence == event?.occurrence) {
      return;
    }
    if (event != null && loadedState.context?.id != event.priority.id) {
      emit(
        loadedState.copyWith(context: event.priority, currentEvent: event),
      );
      return;
    }
    emit(loadedState.copyWith(currentEvent: event));
  }

  /// Focus is the priority of the current activity, which may be more
  /// specific than the context. In the new pomodoro model, focusing does
  /// NOT start a session — start is opt-in via [StartTimer]. This now
  /// just delegates to [setContext] so callers (thread navigation,
  /// priority page) still update the displayed priority.
  void setFocus(Priority? priority) {
    setContext(priority);
  }

  /// Start a pomodoro session for the [context] priority.
  ///
  /// Resolution order for the planned duration:
  ///   1. [override] (the inactive-state preview the user staged with +/-).
  ///   2. The priority's effective `priority_block.duration` — which is
  ///      where pause writes the preserved remaining time, so resume
  ///      picks up exactly where the user left off.
  ///   3. [kDistractionPomodoro] (5m) when supplanting an already-active
  ///      session on a different priority — a quick reminder that the
  ///      user is mid-distraction.
  ///   4. [kDefaultPomodoro] (15m).
  /// All branches are capped at `endFor(priority) − now` so a pomodoro
  /// can never run past the next scheduled event.
  Future<void> startSession({Duration? override}) async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final now = Time.now();
    final hadOtherActive = s.session != null
        && s.session!.at.isNow()
        && s.session!.source == 'active'
        && s.session!.priority?.id != ctx.id;

    // Close out any session on a different priority first.
    if (hadOtherActive) {
      await _closeActiveSessionAndWriteBack(s.session!);
    }

    // Resume-after-pause: if the most recent session for this priority
    // was paused, and its preserved remaining still matches the
    // priority's current pending (i.e. the user didn't manually edit
    // duration in between), restart the same pomodoro with a shifted
    // `pomodoroAt` so the progress ring continues from where it left
    // off rather than snapping back to zero.
    if (override == null) {
      final paused = await Session.latestPausedFor(ctx.id);
      if (paused != null) {
        final originalPomodoro = paused.pomodoro!;
        final elapsedAtPause = paused.end.difference(paused.pomodoroAt!);
        final remainingAtPause = originalPomodoro - elapsedAtPause;
        if (remainingAtPause > Duration.zero
            && s.pendingFor(ctx) == remainingAtPause) {
          final shiftedPomodoroAt = now.subtract(elapsedAtPause);
          await Session.resume(
            ctx,
            end: now.add(const Duration(minutes: 3)),
            pomodoro: originalPomodoro,
            pomodoroAt: shiftedPomodoroAt,
          );
          if (s.previewPomodoro != null) {
            emit(s.copyWith(previewPomodoro: null));
          }
          return;
        }
      }
    }

    final base = override
        ?? s.previewPomodoro
        ?? s.pendingFor(ctx)
        ?? (hadOtherActive ? kDistractionPomodoro : kDefaultPomodoro);
    final pomodoro = _capToEnd(ctx, base);
    if (pomodoro <= Duration.zero) return;

    await Session.resume(
      ctx,
      end: now.add(const Duration(minutes: 3)),
      pomodoro: pomodoro,
      pomodoroAt: now,
    );
    if (s.previewPomodoro != null) {
      emit(s.copyWith(previewPomodoro: null));
    }
  }

  /// Stop the active session (if any) and write back consumed time.
  Future<void> stopSession() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final session = s.session;
    if (session == null || !session.at.isNow()) return;
    if (session.source != 'active') return;
    await _closeActiveSessionAndWriteBack(session);
  }

  /// Adjust the pomodoro by [delta] (positive or negative). When a
  /// session is active and belongs to the context priority, the row's
  /// `pomodoro` field is mutated and saved. When inactive (or when the
  /// session is for a different priority), the change lands in
  /// [NowLoaded.previewPomodoro] which the pill renders.
  ///
  /// Both branches floor at [kMinPomodoro] and cap at `endFor − now`.
  Future<void> adjustPomodoro(Duration delta) async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final session = s.session;
    final isActiveForCtx = session != null
        && session.at.isNow()
        && session.source == 'active'
        && session.priority?.id == ctx.id
        && session.pomodoroAt != null
        && session.pomodoro != null;

    if (isActiveForCtx) {
      final current = session.pomodoro!;
      final proposed = current + delta;
      final clamped = _clampPomodoro(ctx, proposed);
      if (clamped == current) return;
      await Session.fromStore(
        session.copyWith(pomodoro: Value(clamped)),
      ).save();
      return;
    }

    final base = s.previewPomodoro
        ?? s.pendingFor(ctx)
        ?? kDefaultPomodoro;
    final proposed = base + delta;
    final clamped = _clampPomodoro(ctx, proposed);
    emit(s.copyWith(previewPomodoro: clamped));
  }

  /// Snap the displayed remaining time UP to the next [kPomodoroStep]
  /// boundary. For an active context session, this bumps the row's
  /// `pomodoro` so `pomodoroAt + pomodoro = now + nextBoundary`. For
  /// inactive (or non-context active) state, the preview duration the
  /// pill renders is advanced instead.
  Future<void> bumpPomodoroToNext15() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final session = s.session;
    final isActiveForCtx = session != null
        && session.at.isNow()
        && session.source == 'active'
        && session.priority?.id == ctx.id
        && session.pomodoroAt != null
        && session.pomodoro != null;

    if (isActiveForCtx) {
      final now = Time.now();
      final end = session.pomodoroAt!.add(session.pomodoro!);
      final remaining = end.difference(now);
      final next = _nextStepBoundary(remaining);
      final newPomodoro = now.difference(session.pomodoroAt!) + next;
      final clamped = _clampPomodoro(ctx, newPomodoro);
      if (clamped == session.pomodoro) return;
      await Session.fromStore(
        session.copyWith(pomodoro: Value(clamped)),
      ).save();
      return;
    }

    final base = s.previewPomodoro
        ?? s.pendingFor(ctx)
        ?? Duration.zero;
    final next = _nextStepBoundary(base);
    final clamped = _clampPomodoro(ctx, next);
    if (clamped == s.previewPomodoro) return;
    emit(s.copyWith(previewPomodoro: clamped));
  }

  /// Strictly greater multiple of [kPomodoroStep]. Sub-minute remainders
  /// round up first so `14m59s` snaps to `30m`, not `15m`.
  static Duration _nextStepBoundary(Duration current) {
    final stepSeconds = kPomodoroStep.inSeconds;
    final currentSeconds = current.inSeconds <= 0 ? 0 : current.inSeconds;
    final nextSeconds =
        ((currentSeconds ~/ stepSeconds) + 1) * stepSeconds;
    return Duration(seconds: nextSeconds);
  }

  Duration _capToEnd(Priority priority, Duration desired) {
    final end = loadedState.endFor(priority);
    if (end == null) return desired;
    final headroom = end.difference(Time.now());
    if (headroom <= Duration.zero) return Duration.zero;
    return desired < headroom ? desired : headroom;
  }

  Duration _clampPomodoro(Priority priority, Duration desired) {
    var d = desired;
    if (d < kMinPomodoro) d = kMinPomodoro;
    return _capToEnd(priority, d);
  }
}
