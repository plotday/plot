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
    _trackTick = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _onTrackTick(),
    );
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
  ///      [_closeActiveSession] (which also writes the
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
      await _closeActiveSession(session);
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

  /// Close out the currently-active foreground session by pinning its
  /// `end` to `now`. The remaining time in the planned pomodoro window
  /// stays encoded on the session row itself (`pomodoroAt + pomodoro -
  /// end`); the resume path reads it directly, and
  /// `watchPendingDisplay` derives the agenda's live display from the
  /// same row across devices. `priority_block.duration` is intentionally
  /// not touched — it's the user-configured base duration for the
  /// priority, not a resume cache.
  Future<void> _closeActiveSession(Session existing) async {
    final now = Time.now();
    final closed = Session.fromStore(existing.copyWith(end: now));
    await closed.save();
  }

  /// Live remaining-duration stream for the agenda block header. The
  /// resolution order is:
  ///
  ///   1. Active session for this priority → `pomodoroAt + pomodoro − now`.
  ///   2. Paused **explicit** session for this priority → the remaining
  ///      time frozen at pause (`pomodoroAt + pomodoro − end`), so a
  ///      paused 23-minute timer keeps showing 23 minutes until the user
  ///      resumes or stops.
  ///   3. Otherwise → the user-configured `priority_block.duration` at
  ///      [Time.now].
  ///
  /// All three branches sync cleanly across devices: the session row is
  /// the source of truth for in-flight/paused state, and `priority_block`
  /// is the source of truth for the configured base. The emitted value
  /// is wrapped in [PriorityPendingDisplay] so callers can distinguish
  /// "subscription hasn't emitted yet" (still null) from "subscription
  /// emitted null because no row contributes" — important for the
  /// agenda gutter, which falls back to the stale agenda-model cascade
  /// slice only during the pre-emission gap and never afterward.
  static Stream<PriorityPendingDisplay> watchPendingDisplay(
    PriorityId priorityId,
  ) {
    return Rx.combineLatest4(
      streamPriorityBlocksGroupedByPriority(),
      Session.watchCurrent(),
      Session.watchLatestPausedFor(priorityId),
      Stream<void>.periodic(const Duration(minutes: 1), (_) {}).startWith(null),
      (blocksByPriority, currentSession, pausedExplicit, _) {
        final now = Time.now();
        final isActiveForThisPriority =
            currentSession != null &&
            currentSession.priority?.id == priorityId &&
            currentSession.at.isNow() &&
            currentSession.pomodoroAt != null &&
            currentSession.pomodoro != null;
        if (isActiveForThisPriority) {
          final end =
              currentSession.pomodoroAt!.add(currentSession.pomodoro!);
          final remaining = end.difference(now);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        if (pausedExplicit != null) {
          final originalEnd =
              pausedExplicit.pomodoroAt!.add(pausedExplicit.pomodoro!);
          final remaining = originalEnd.difference(pausedExplicit.end);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        final rows = blocksByPriority[priorityId] ?? const [];
        return PriorityPendingDisplay(
          duration: effectivePriorityDurationAt(
            moment: now,
            blocksForPriority: rows,
          ),
        );
      },
    );
  }

  /// Apply a ±15m bump to the priority's displayed pending duration,
  /// writing to whichever row is the current display source so the
  /// edited value is what the user sees.
  ///
  ///   * [newDisplayed] is null (user pressed − on a value ≤ 15m, asking
  ///     to clear) → collapse any session contributing to the display
  ///     **and** archive `priority_block.duration`. Without clearing
  ///     both, ending a session that was masking a non-null
  ///     `priority_block.duration` would re-reveal the masked value and
  ///     the gutter would still show time.
  ///   * Active or paused-explicit session present and remaining stays
  ///     positive → rewrite that session's `pomodoro` so the visible
  ///     remaining shifts by the delta.
  ///   * Otherwise → call [PriorityBlock.setPendingDuration] with the new
  ///     value.
  ///
  /// The session(s) acted on are looked up live from the DB at apply
  /// time rather than read from [display] — the snapshot the buttons
  /// were rendering against can drift between successive clicks (the
  /// active session row's `end` is bumped each minute, distraction
  /// handoffs can swap rows out from under us), and applying a delta to
  /// a stale row would write to the wrong session id and surface as
  /// "the buttons don't do anything" or "the value toggles back".
  ///
  /// [currentDisplayed] and [newDisplayed] are the value the user saw
  /// and the value they intend after the bump.
  static Future<void> applyPendingBump({
    required PriorityId priorityId,
    required Duration? currentDisplayed,
    required Duration? newDisplayed,
  }) async {
    final delta =
        (newDisplayed ?? Duration.zero) - (currentDisplayed ?? Duration.zero);
    if (delta == Duration.zero) return;

    // Live lookups — see method-level doc for why we don't trust a
    // [PriorityPendingDisplay] snapshot here.
    final liveActive = await Session.activeFor(priorityId);
    final livePaused = liveActive == null
        ? await Session.latestPausedFor(priorityId)
        : null;
    final liveSource = liveActive ?? livePaused;

    final clearing = newDisplayed == null;
    if (clearing) {
      if (liveSource != null && liveSource.pomodoroAt != null) {
        final anchorOffset = liveSource.at.isNow()
            ? Time.now().difference(liveSource.pomodoroAt!)
            : liveSource.end.difference(liveSource.pomodoroAt!);
        final collapsed = liveSource.at.isNow()
            ? liveSource.copyWith(
                end: Time.now(), pomodoro: Value(anchorOffset))
            : liveSource.copyWith(pomodoro: Value(anchorOffset));
        await Session.fromStore(collapsed).save();
      }
      await PriorityBlock.setPendingDuration(priorityId, null);
      return;
    }

    if (liveSource != null &&
        liveSource.pomodoro != null &&
        liveSource.pomodoroAt != null) {
      final newPomodoro = liveSource.pomodoro! + delta;
      await Session.fromStore(
        liveSource.copyWith(pomodoro: Value(newPomodoro)),
      ).save();
      return;
    }

    await PriorityBlock.setPendingDuration(priorityId, newDisplayed);
  }


  /// Context is the priority being displayed, which may
  /// be more general than the focus.
  ///
  /// Distraction handoff: when the user navigates *away from* a priority
  /// that owned the active session, close it and start a fresh one on
  /// the new context (fallback duration [kDistractionPomodoro]).
  ///
  /// Why the handoff is gated on `prior.context == session.priority`:
  /// the session is shared state across clients. A second client may be
  /// sitting on Priority B while a session runs on Priority A. Without
  /// this gate, the user navigating B → D on the second client would
  /// silently hijack the A-side session — they were never viewing A.
  /// With the gate, navigation only moves the session when the user was
  /// actually looking at the priority that owned it. Navigating *to* the
  /// session's priority is always a pure view change (the pill becomes
  /// active because session.priority now matches ctx).
  void setContext(Priority? priority) async {
    final prior = loadedState;
    if (prior.context?.id == priority?.id) return;
    // Sticky-until-navigated-away: clear currentEvent whenever the
    // displayed priority changes to one that doesn't own the event.
    final currentEvent = prior.currentEvent;
    final keepEvent =
        currentEvent != null && currentEvent.priority.id == priority?.id;
    emit(
      prior.copyWith(
        context: priority,
        currentEvent: keepEvent ? currentEvent : null,
        // Staged duration is per-priority — drop it whenever the user
        // navigates to a different priority.
        previewPomodoro: null,
      ),
    );

    final wasActive =
        prior.session != null &&
        prior.session!.at.isNow() &&
        prior.session!.source == 'active' &&
        prior.session!.pomodoroAt != null &&
        prior.session!.priority?.id == prior.context?.id;
    if (wasActive && priority != null) {
      await _startDistraction();
    }
  }

  /// Distraction handoff: the user navigated away from a priority that
  /// owned the active session, so close that session and open a fresh
  /// 5-minute one on [context]. Marked `explicit=false` so a future
  /// resume on this priority falls through to the configured base
  /// duration instead of reviving a stale 5-minute reminder.
  ///
  /// Always 5 minutes per the spec — `priority_block.duration` is
  /// intentionally ignored for auto-starts. The user can promote the
  /// session to explicit (and a real duration) by pressing Add time,
  /// which flips the row's `explicit` flag and bumps the pomodoro.
  Future<void> _startDistraction() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final priorActive =
        s.session != null &&
        s.session!.at.isNow() &&
        s.session!.source == 'active' &&
        s.session!.priority?.id != ctx.id;
    if (priorActive) {
      await _closeActiveSession(s.session!);
    }

    final now = Time.now();
    final pomodoro = _capToEnd(ctx, kDistractionPomodoro);
    if (pomodoro <= Duration.zero) return;

    await Session.resume(
      ctx,
      end: now.add(const Duration(minutes: 3)),
      pomodoro: pomodoro,
      pomodoroAt: now,
      explicit: false,
    );
    if (s.previewPomodoro != null) {
      emit(s.copyWith(previewPomodoro: null));
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
      emit(loadedState.copyWith(context: event.priority, currentEvent: event));
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

  /// Start an **explicit** pomodoro session for the [context] priority
  /// (the user pressed Start, or a caller is opening a fresh timer on
  /// the user's behalf). The distraction-handoff path goes through
  /// [_startDistraction] instead — this method always marks the new
  /// session `explicit = true`.
  ///
  /// Resolution order for the planned duration:
  ///   1. [override] — caller-supplied; bypasses every other branch.
  ///   2. Resume from the most recent paused **explicit** session for
  ///      this priority (`Session.latestPausedFor`), shifting its
  ///      `pomodoroAt` so the progress ring continues from where the
  ///      user left off rather than snapping back to zero.
  ///   3. The inactive-state preview the user staged via Add/Remove time.
  ///   4. `priority_block.duration` for the matching priority (capped to
  ///      the time until the next scheduled event by [_capToEnd]).
  ///   5. [kDefaultPomodoro] (15 m).
  ///
  /// All branches are capped at `pomodoroEndCap(priority) − now` so a
  /// pomodoro can never run past the next scheduled event.
  Future<void> startSession({Duration? override}) async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final now = Time.now();
    final hadOtherActive =
        s.session != null &&
        s.session!.at.isNow() &&
        s.session!.source == 'active' &&
        s.session!.priority?.id != ctx.id;

    // Close out any session on a different priority first.
    if (hadOtherActive) {
      await _closeActiveSession(s.session!);
    }

    // Resume-after-pause: if the most recent explicit session for this
    // priority was paused, restart the same pomodoro with a shifted
    // `pomodoroAt` so the progress ring continues from where it left
    // off. The paused-session row is now the source of truth — no
    // longer gated on `priority_block.duration` matching the preserved
    // remaining.
    if (override == null) {
      final paused = await Session.latestPausedFor(ctx.id);
      if (paused != null) {
        final originalPomodoro = paused.pomodoro!;
        final elapsedAtPause = paused.end.difference(paused.pomodoroAt!);
        final remainingAtPause = originalPomodoro - elapsedAtPause;
        if (remainingAtPause > Duration.zero) {
          final shiftedPomodoroAt = now.subtract(elapsedAtPause);
          await Session.resume(
            ctx,
            end: now.add(const Duration(minutes: 3)),
            pomodoro: originalPomodoro,
            pomodoroAt: shiftedPomodoroAt,
            explicit: true,
          );
          if (s.previewPomodoro != null) {
            emit(s.copyWith(previewPomodoro: null));
          }
          return;
        }
      }
    }

    // While a scheduled event for this priority is in progress, default
    // the new pomodoro to the time remaining in the event. This is the
    // restart path after a Pause/Stop on the auto-displayed event timer
    // (which writes a 'skip' marker) — the user pressing Start should
    // resume tracking the event rather than spinning up an unrelated
    // window. Caller [override] and the staged inactive preview still
    // win when set.
    Duration? eventRemaining;
    final event = s.inProgressEventForContext;
    if (event != null && event.priority.id == ctx.id) {
      final end = event.at?.end;
      if (end != null && end.isAfter(now)) {
        eventRemaining = end.difference(now);
      }
    }
    final base =
        override ??
        s.previewPomodoro ??
        eventRemaining ??
        s.pendingFor(ctx) ??
        kDefaultPomodoro;
    final pomodoro = _capToEnd(ctx, base);
    if (pomodoro <= Duration.zero) return;

    await Session.resume(
      ctx,
      end: now.add(const Duration(minutes: 3)),
      pomodoro: pomodoro,
      pomodoroAt: now,
      explicit: true,
    );
    if (s.previewPomodoro != null) {
      emit(s.copyWith(previewPomodoro: null));
    }
  }

  /// Pause the active session: close it without altering its planned
  /// pomodoro window, so a future Start on the same priority can resume
  /// from the remaining time. See [endSession] for the variant that
  /// completely ends the session instead.
  Future<void> stopSession() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final session = s.session;
    if (session == null || !session.at.isNow()) return;
    if (session.source != 'active') return;
    await _closeActiveSession(session);
  }

  /// Fully end the active session — the next Start on the same priority
  /// will open a fresh pomodoro rather than resuming this one. We
  /// achieve "not paused" by truncating `pomodoro` so the planned window
  /// matches the actual run time (`pomodoroAt + pomodoro == now`),
  /// which fails [Session.latestPausedFor]'s "end strictly before
  /// natural end" gate.
  Future<void> endSession() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final session = s.session;
    if (session == null || !session.at.isNow()) return;
    if (session.source != 'active') return;

    final now = Time.now();
    Duration? truncatedPomodoro;
    if (session.pomodoroAt != null) {
      final elapsed = now.difference(session.pomodoroAt!);
      truncatedPomodoro = elapsed > Duration.zero ? elapsed : Duration.zero;
    }
    final closed = Session.fromStore(
      session.copyWith(
        end: now,
        pomodoro: truncatedPomodoro == null
            ? const Value.absent()
            : Value(truncatedPomodoro),
      ),
    );
    await closed.save();
  }

  /// Adjust the pomodoro by [delta] (positive or negative). When a
  /// session is active and belongs to the context priority, the row's
  /// `pomodoro` field is mutated and saved. When inactive (or when the
  /// session is for a different priority), the change lands in
  /// [NowLoaded.previewPomodoro] which the pill renders.
  ///
  /// Both branches floor at [kMinPomodoro] and cap at `pomodoroEndCap − now`.
  Future<void> adjustPomodoro(Duration delta) async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final session = s.session;
    final isActiveForCtx =
        session != null &&
        session.at.isNow() &&
        session.source == 'active' &&
        session.priority?.id == ctx.id &&
        session.pomodoroAt != null &&
        session.pomodoro != null;

    if (isActiveForCtx) {
      final current = session.pomodoro!;
      final proposed = current + delta;
      final clamped = _clampPomodoro(ctx, proposed, anchor: session.pomodoroAt);
      if (clamped == current) return;
      await Session.fromStore(
        session.copyWith(pomodoro: Value(clamped)),
      ).save();
      return;
    }

    final base = s.previewPomodoro ?? s.pendingFor(ctx) ?? kDefaultPomodoro;
    final proposed = base + delta;
    final clamped = _clampPomodoro(ctx, proposed);
    emit(s.copyWith(previewPomodoro: clamped));
  }

  /// Shrink the displayed remaining time by [kPomodoroStep] (15m). If
  /// less than 15m of remaining time is left, snap remaining to
  /// [kMinPomodoro] (5m) instead so the user always has a meaningful
  /// floor to land on. For an active context session this rewrites
  /// `pomodoro` so `pomodoroAt + pomodoro = now + newRemaining`; for
  /// inactive (or non-context active) state, [NowLoaded.previewPomodoro]
  /// is updated instead.
  Future<void> decreasePomodoro() async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final ctx = s.context;
    if (ctx == null) return;

    final session = s.session;
    final isActiveForCtx =
        session != null &&
        session.at.isNow() &&
        session.source == 'active' &&
        session.priority?.id == ctx.id &&
        session.pomodoroAt != null &&
        session.pomodoro != null;

    if (isActiveForCtx) {
      final now = Time.now();
      final elapsed = now.difference(session.pomodoroAt!);
      final remaining = session.pomodoro! - elapsed;
      final newRemaining = remaining > kPomodoroStep
          ? remaining - kPomodoroStep
          : kMinPomodoro;
      final clamped = _clampPomodoro(
        ctx,
        elapsed + newRemaining,
        anchor: session.pomodoroAt,
      );
      if (clamped == session.pomodoro) return;
      await Session.fromStore(
        session.copyWith(pomodoro: Value(clamped)),
      ).save();
      return;
    }

    final base = s.previewPomodoro ?? s.pendingFor(ctx) ?? kDefaultPomodoro;
    final newBase = base > kPomodoroStep ? base - kPomodoroStep : kMinPomodoro;
    final clamped = _clampPomodoro(ctx, newBase);
    if (clamped == s.previewPomodoro) return;
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
    final isActiveForCtx =
        session != null &&
        session.at.isNow() &&
        session.source == 'active' &&
        session.priority?.id == ctx.id &&
        session.pomodoroAt != null &&
        session.pomodoro != null;

    if (isActiveForCtx) {
      final now = Time.now();
      final end = session.pomodoroAt!.add(session.pomodoro!);
      final remaining = end.difference(now);
      final next = _nextStepBoundary(remaining);
      final newPomodoro = now.difference(session.pomodoroAt!) + next;
      final clamped = _clampPomodoro(
        ctx,
        newPomodoro,
        anchor: session.pomodoroAt,
      );
      // Promote auto-started 5m distractions to explicit when the user
      // extends them — a clear signal that they want this priority's
      // session to outlive the next handoff. Already-explicit sessions
      // keep `explicit = true` (no-op).
      final promoteExplicit = !session.explicit;
      if (clamped == session.pomodoro && !promoteExplicit) return;
      await Session.fromStore(
        session.copyWith(
          pomodoro: Value(clamped),
          explicit: promoteExplicit ? true : null,
        ),
      ).save();
      return;
    }

    final base = s.previewPomodoro ?? s.pendingFor(ctx) ?? Duration.zero;
    final next = _nextStepBoundary(base);
    final clamped = _clampPomodoro(ctx, next);
    if (clamped == s.previewPomodoro) return;
    emit(s.copyWith(previewPomodoro: clamped));
  }

  /// Strictly greater multiple of [kPomodoroStep] than what the pill is
  /// currently showing. The pill rounds remaining UP to the nearest
  /// minute (`_formatMinutes` ceil), so the user sees `15m` for any
  /// remaining in `(14m, 15m]`. Without ceiling here first, pressing `+`
  /// at displayed-`15m` (actual `14m58s`) would target `15m` again — the
  /// displayed value would not budge. Ceiling to whole minutes first
  /// keeps "press `+` advances the visible label" true: `14m58s` →
  /// ceiled `15m` → next boundary `30m`.
  static Duration _nextStepBoundary(Duration current) {
    final stepSeconds = kPomodoroStep.inSeconds;
    if (current.inSeconds <= 0) return kPomodoroStep;
    final ceiledMinutes = (current.inSeconds + 59) ~/ 60;
    final ceiledSeconds = ceiledMinutes * 60;
    final nextSeconds = ((ceiledSeconds ~/ stepSeconds) + 1) * stepSeconds;
    return Duration(seconds: nextSeconds);
  }

  /// Cap a pomodoro length so its endpoint doesn't cross [pomodoroEndCap].
  ///
  /// [desired] is interpreted as a length measured from [anchor] (defaults
  /// to [Time.now]). For an active session, callers pass `pomodoroAt` so
  /// the maximum allowable length is `capEnd − pomodoroAt`. For preview
  /// (inactive) state, the timer will start at `now`, so the default
  /// `now` anchor gives `capEnd − now`. Mixing these up makes each press
  /// of `+` clamp the new duration back down to the existing remaining
  /// time (or, when they coincide, no-op via the equality guard in the
  /// callers).
  Duration _capToEnd(Priority priority, Duration desired, {DateTime? anchor}) {
    final end = loadedState.pomodoroEndCap(priority);
    if (end == null) return desired;
    final from = anchor ?? Time.now();
    final maxAllowed = end.difference(from);
    if (maxAllowed <= Duration.zero) return Duration.zero;
    return desired < maxAllowed ? desired : maxAllowed;
  }

  Duration _clampPomodoro(
    Priority priority,
    Duration desired, {
    DateTime? anchor,
  }) {
    var d = desired;
    if (d < kMinPomodoro) d = kMinPomodoro;
    return _capToEnd(priority, d, anchor: anchor);
  }
}

/// Snapshot of a priority's displayed pending duration. Wrapped in a
/// non-nullable class so callers can distinguish "subscription hasn't
/// emitted yet" (still holding `null`) from "subscription emitted null
/// because no row contributes." See [NowBloc.watchPendingDisplay] for
/// the resolution order across active/paused-explicit sessions and
/// `priority_block.duration`.
class PriorityPendingDisplay extends Equatable {
  const PriorityPendingDisplay({this.duration});

  /// The duration the user sees in the gutter. Null when no row
  /// contributes a value.
  final Duration? duration;

  @override
  List<Object?> get props => [duration];
}
