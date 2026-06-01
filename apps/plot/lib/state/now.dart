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

  /// Whether the user is currently viewing the synthetic "Everything" feed.
  bool get everything => state is NowLoaded && loadedState.everything;

  StreamSubscription<void>? _subscription;
  Timer? _trackTick;

  /// Local date at which the current `_subscription` was started. When
  /// the local date changes (across midnight), the priority_block watch
  /// is re-issued so its bounded UNION query re-narrows.
  DateTime? _subscriptionLocalDate;

  /// Tail of the serialized pomodoro-adjustment chain. Add/Remove time
  /// shortcuts (and [adjustPomodoro]) all race through here so rapid
  /// presses are processed one at a time. Without this, each press
  /// reads `state.session.pomodoro` before Drift's watcher has emitted
  /// the previous save, so two fast `+` presses both compute "current
  /// + 15m" from the same stale baseline and the second increment is
  /// silently dropped.
  Future<void> _pomodoroOpChain = Future<void>.value();

  /// Most recently saved `pomodoro` for the active context session,
  /// ahead of (or matching) what `state.session.pomodoro` shows. Used
  /// as the baseline for the next adjustment so chained ops compound
  /// even when the watcher hasn't emitted yet. Cleared whenever the
  /// session id changes or the watcher catches up to this value.
  Duration? _intendedPomodoro;
  Uuid? _intendedSessionId;

  /// Bumped before every `pausedFocus` clear or new derivation. The
  /// listener captures its generation before awaiting; when an in-flight
  /// derivation completes after the counter has moved on, its result is
  /// dropped instead of overwriting a newer (often explicit-null) value.
  int _pausedFocusGeneration = 0;

  @override
  Future<void> close() {
    stop();
    return super.close();
  }

  Future<void> start() {
    final nowSubscriptionStart = Time.now();
    _subscriptionLocalDate = DateTime(
      nowSubscriptionStart.year,
      nowSubscriptionStart.month,
      nowSubscriptionStart.day,
    );
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
              selectedBlockId: prior?.selectedBlockId,
              previewPomodoro: prior?.previewPomodoro,
              // Preserve the synthetic "Everything" feed flag across watcher
              // re-emissions. Without this, any background sync or the
              // 1-minute track tick rebuilds NowLoaded with the constructor
              // default (false), silently dropping the user from Everything
              // back to Inbox. Mirrors the other prior-forwarded fields above.
              everything: prior?.everything ?? false,
            );
          },
        ).listen(
          (state) async {
            final ctx = state.context;
            final generation = ++_pausedFocusGeneration;
            final pausedFocus =
                ctx == null ? null : await _resolvePausedFocus(ctx);
            if (isClosed || generation != _pausedFocusGeneration) return;
            emit(state.copyWith(pausedFocus: pausedFocus));
            // Watcher caught up: if the emitted session matches our
            // tracked intent (or is a different session entirely),
            // drop the intent so subsequent ops read from state again.
            final sessionId = state.session?.id;
            if (sessionId != _intendedSessionId ||
                state.session?.pomodoro == _intendedPomodoro) {
              _intendedPomodoro = null;
              _intendedSessionId = null;
            }
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
    // `at.isNow()` stays true, auto-stop when the 5-minute grace expires,
    // and drive auto-start when the context priority has a covering focus
    // block row.
    // Auto-start can fire from [_onTrackTick] when the context priority has
    // a covering focus block row.
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

  /// Maintenance tick for the active pomodoro session.
  ///
  /// Behavior:
  ///   1. Skip when the in-flight day has changed (date rollover).
  ///   2. While a `source='active'` session exists for the context:
  ///      - When `pomodoroAt + pomodoro + kPomodoroGrace` is reached,
  ///        close the session (and archive the covering focus block
  ///        row to prevent immediate auto-restart).
  ///      - When the session's [end] is about to be reached, bump it
  ///        forward so the watcher's window stays open.
  ///   3. Drive auto-start: if [context] has a focus block row whose
  ///      window covers `now`, start (or resume) a session for it. The
  ///      idempotency guard in [_maybeAutoStart] makes this safe to
  ///      call every tick.
  Future<void> _onTrackTick() async {
    final tickNow = Time.now();
    final tickDate = DateTime(tickNow.year, tickNow.month, tickNow.day);
    if (_subscriptionLocalDate != null && tickDate != _subscriptionLocalDate) {
      // Local date rolled over — re-subscribe so the priority_block
      // query re-binds today_midnight to the new day. Return so the
      // session maintenance below runs against the fresh subscription's
      // next emission rather than the about-to-be-cancelled one.
      _resubscribePriorityBlocks();
      return;
    }

    if (state is! NowLoaded) return;
    final s = loadedState;
    final session = s.session;

    // Session maintenance: bump end, auto-close on grace expiry.
    if (session != null &&
        session.source == 'active' &&
        session.pomodoroAt != null &&
        session.pomodoro != null) {
      final now = Time.now();
      final graceEnd = session.pomodoroAt!
          .add(session.pomodoro!)
          .add(kPomodoroGrace);
      if (!now.isBefore(graceEnd)) {
        await _closeActiveSession(session);
        final ctx = s.context;
        if (ctx != null) {
          await _archiveCoveringRow(ctx, now);
        }
      } else if (session.at.end.isBefore(now.add(const Duration(minutes: 1)))) {
        // Extend forward so `at.isNow()` keeps holding through the next
        // tick. Mirrors the 3-minute lookahead that `setFocus` originally
        // wrote when sessions were auto-started.
        await Session.fromStore(
          session.copyWith(end: now.add(const Duration(minutes: 3))),
        ).save();
      }
    }

    final ctx = s.context;
    if (ctx != null) {
      await _maybeAutoStart(ctx);
    }
  }

  /// Tear down and rebuild the combined subscription so the
  /// `streamPriorityBlocksGroupedByPriority` query re-binds its
  /// `today_midnight` parameter. Called on local-date rollover.
  void _resubscribePriorityBlocks() {
    _subscription?.cancel();
    _subscription = null;
    _trackTick?.cancel();
    _trackTick = null;
    // start() resets _subscriptionLocalDate per its initialization,
    // so the next rollover will fire correctly.
    start();
  }

  /// Close out the currently-active foreground session by pinning its
  /// `end` to `now`. The remaining time in the planned pomodoro window
  /// stays encoded on the session row itself (`pomodoroAt + pomodoro -
  /// end`); the resume path reads it directly, and `watchBlockDisplay`
  /// derives the agenda's live display from the same row across devices.
  /// `priority_block.duration` is intentionally not touched — it's the
  /// user-configured base duration for the priority, not a resume cache.
  Future<void> _closeActiveSession(Session existing) async {
    final now = Time.now();
    final closed = Session.fromStore(existing.copyWith(end: now));
    await closed.save();
  }

  /// Live remaining-duration stream for a specific agenda block.
  /// Resolution order:
  ///   1. Active session for this priority whose `pomodoroAt` falls in
  ///      `[blockStart, blockEnd)` AND `at.isNow()` →
  ///      `pomodoroAt + pomodoro - now`.
  ///   2. Paused-explicit session for this priority whose `pomodoroAt`
  ///      falls in `[blockStart, blockEnd)` →
  ///      `pomodoroAt + pomodoro - end` (frozen remaining at pause).
  ///   3. Otherwise null — the caller composes this stream's value with
  ///      the block's static `cascadeDuration` from the agenda model
  ///      (`live ?? block.cascadeDuration`). The agenda builder's
  ///      multi-block walker (`_attachBlockDurations`) is the single
  ///      source of truth for which row attaches to which block;
  ///      duplicating that resolve here as a single-block walker would
  ///      let a row consumed by an earlier block leak onto later blocks.
  static Stream<PriorityPendingDisplay> watchBlockDisplay({
    required PriorityId priorityId,
    required DateTime blockStart,
    required DateTime blockEnd,
  }) {
    bool inWindow(DateTime t) =>
        !t.isBefore(blockStart) && t.isBefore(blockEnd);

    return Rx.combineLatest3(
      Session.watchCurrent(),
      Session.watchLatestPausedFor(priorityId),
      Stream<void>.periodic(const Duration(minutes: 1), (_) {}).startWith(null),
      (currentSession, pausedExplicit, _) {
        final now = Time.now();
        final activeInBlock =
            currentSession != null &&
            currentSession.priority?.id == priorityId &&
            currentSession.at.isNow() &&
            currentSession.pomodoroAt != null &&
            currentSession.pomodoro != null &&
            inWindow(currentSession.pomodoroAt!);
        if (activeInBlock) {
          final end =
              currentSession.pomodoroAt!.add(currentSession.pomodoro!);
          final remaining = end.difference(now);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        if (pausedExplicit != null &&
            pausedExplicit.pomodoroAt != null &&
            inWindow(pausedExplicit.pomodoroAt!)) {
          final originalEnd =
              pausedExplicit.pomodoroAt!.add(pausedExplicit.pomodoro!);
          final remaining = originalEnd.difference(pausedExplicit.end);
          return PriorityPendingDisplay(
            duration: remaining > Duration.zero ? remaining : null,
          );
        }
        return const PriorityPendingDisplay();
      },
    );
  }

  /// Block-aware writer for an agenda block's pending duration. Routes
  /// the write to whichever row is the current display source — a
  /// session row when one is anchored inside `[blockStart, blockEnd)`,
  /// otherwise `priority_block` at `effective_at = blockStart`. Same
  /// routing logic as the priority-level bump path, but scoped to this
  /// block's window so multi-block days write independent rows.
  static Future<void> applyBlockBump({
    required PriorityId priorityId,
    required DateTime blockStart,
    required DateTime blockEnd,
    required Duration? currentDisplayed,
    required Duration? newDisplayed,
  }) async {
    final delta =
        (newDisplayed ?? Duration.zero) - (currentDisplayed ?? Duration.zero);
    if (delta == Duration.zero) return;

    bool inWindow(DateTime t) =>
        !t.isBefore(blockStart) && t.isBefore(blockEnd);

    final liveActive = await Session.activeFor(priorityId);
    final liveInBlock = liveActive != null &&
        liveActive.pomodoroAt != null &&
        inWindow(liveActive.pomodoroAt!);
    Session? livePaused;
    bool pausedInBlock = false;
    if (!liveInBlock) {
      livePaused = await Session.latestPausedFor(priorityId);
      pausedInBlock = livePaused != null &&
          livePaused.pomodoroAt != null &&
          inWindow(livePaused.pomodoroAt!);
    }
    final liveSource = liveInBlock
        ? liveActive
        : pausedInBlock
            ? livePaused
            : null;

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
      await PriorityBlock.setBlockDuration(
        priorityId: priorityId,
        blockStart: blockStart,
        newDuration: null,
      );
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

    await PriorityBlock.setBlockDuration(
      priorityId: priorityId,
      blockStart: blockStart,
      newDuration: newDisplayed,
    );
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
  ///
  /// [selectedBlockId] records a block the user tapped *in the agenda*
  /// (see [NowLoaded.selectedBlockId]). Resolution:
  ///   - A non-null id (an agenda block tap) always becomes the new
  ///     selection, even when it re-targets a different block of the
  ///     priority already in view.
  ///   - A null id (every other caller) clears the selection only on a
  ///     real priority *change*. A same-priority re-assertion — e.g.
  ///     [PriorityPage] calling this on mount with the priority the
  ///     agenda tap just selected — preserves it, so the highlight
  ///     survives the navigation that the tap itself triggered.
  void setContext(
    Priority? priority, {
    String? selectedBlockId,
    bool? everything,
  }) async {
    final prior = loadedState;
    final samePriority = prior.context?.id == priority?.id;
    final newSelectedBlockId =
        selectedBlockId ?? (samePriority ? prior.selectedBlockId : null);
    // `everything` is nullable so callers that don't care (e.g. the bloc
    // provider re-publishing the loaded context) preserve the current value,
    // while commands set it explicitly: Everything = true, any ordinary
    // priority navigation = false.
    final newEverything = everything ?? prior.everything;

    if (samePriority) {
      // No real navigation — only the agenda selection or the Everything
      // flag can change (e.g. toggling Inbox ⇄ Everything, both rooted on
      // the same root priority).
      if (prior.selectedBlockId == newSelectedBlockId &&
          prior.everything == newEverything) {
        return;
      }
      emit(
        prior.copyWith(
          selectedBlockId: newSelectedBlockId,
          everything: newEverything,
        ),
      );
      return;
    }

    // Real priority change. Sticky-until-navigated-away: clear
    // currentEvent unless the new priority still owns the event.
    final currentEvent = prior.currentEvent;
    final keepEvent =
        currentEvent != null && currentEvent.priority.id == priority?.id;
    emit(
      prior.copyWith(
        context: priority,
        currentEvent: keepEvent ? currentEvent : null,
        selectedBlockId: newSelectedBlockId,
        // Staged duration is per-priority — drop it whenever the user
        // navigates to a different priority.
        previewPomodoro: null,
        everything: newEverything,
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

    if (priority != null) {
      // Fire-and-forget — the resulting session emission is observed by
      // PriorityBloc through the existing NowBloc subscription.
      unawaited(_maybeAutoStart(priority));
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
    // Note: we don't clear `pausedFocus` here. `_startDistraction` only
    // fires after [setContext] has emitted a new context priority — the
    // next combineLatest tick will call `_resolvePausedFocus(newCtx)`,
    // which typically returns null for the new priority. The asymmetry
    // with [startSession]'s explicit clear is intentional.
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
    // Selecting an event is its own direct selection — drop any block
    // the user had tapped so the two highlight sources can't fight.
    // Clearing the event (event == null) leaves the block selection
    // alone; the highlight precedence already prefers an event over a
    // block, so there's nothing to resolve on deselect.
    final selectedBlockId = event != null ? null : loadedState.selectedBlockId;
    if (event != null && loadedState.context?.id != event.priority.id) {
      emit(
        loadedState.copyWith(
          context: event.priority,
          currentEvent: event,
          selectedBlockId: selectedBlockId,
        ),
      );
      return;
    }
    emit(
      loadedState.copyWith(
        currentEvent: event,
        selectedBlockId: selectedBlockId,
      ),
    );
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

    // Clear the sliding paused-focus block immediately so the agenda
    // stops showing it the instant the user presses Start. The next
    // stream emission will recompute pausedFocus from scratch (and
    // return null because the session will then be active, not paused).
    // Bump the generation counter first so any in-flight `_resolvePausedFocus`
    // that started before the user pressed Start is discarded rather than
    // overwriting this explicit null once it completes.
    _pausedFocusGeneration++;
    emit(s.copyWith(pausedFocus: null));

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
          _emitOptimisticSession(
            ctx,
            pomodoro: originalPomodoro,
            pomodoroAt: shiftedPomodoroAt,
            now: now,
          );
          await _ensureFocusRow(ctx, shiftedPomodoroAt, originalPomodoro);
          await Session.resume(
            ctx,
            end: now.add(const Duration(minutes: 3)),
            pomodoro: originalPomodoro,
            pomodoroAt: shiftedPomodoroAt,
            explicit: true,
          );
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
    //
    // Resume-after-event-pause: if a live 'skip' marker exists for the
    // in-progress event (auto-event-timer was paused via Stop), shift
    // the new session so the ring continues from its engaged-before-pause
    // fill instead of resetting to zero. Anchor `pomodoroAt` at
    // `eventStart + pauseDuration` and shrink `pomodoro` by the same
    // amount so progress = engagedBeforePause / (eventTotal − pauseDuration)
    // and remaining = eventEnd − now. Clamp the skip's end to `now` so it
    // (a) accurately records the actual pause window and (b) won't re-fire
    // this branch on a later Start after the resumed session burns down.
    Duration? eventRemaining;
    final event = s.inProgressEventForContext;
    if (event != null && event.priority.id == ctx.id) {
      final eventStart = event.at?.start;
      final end = event.at?.end;
      if (eventStart != null && end != null && end.isAfter(now)) {
        eventRemaining = end.difference(now);
        if (override == null && event.scheduleId != null) {
          final skip = await Session.latestSkipFor(
            event.scheduleId!,
            occurrenceAt: eventStart,
          );
          if (skip != null &&
              !skip.start.isBefore(eventStart) &&
              skip.start.isBefore(now) &&
              skip.end.isAfter(now)) {
            final pauseDuration = now.difference(skip.start);
            final eventTotal = end.difference(eventStart);
            final newPomodoro = eventTotal - pauseDuration;
            if (newPomodoro > Duration.zero) {
              final shiftedPomodoroAt = eventStart.add(pauseDuration);
              _emitOptimisticSession(
                ctx,
                pomodoro: newPomodoro,
                pomodoroAt: shiftedPomodoroAt,
                now: now,
              );
              await _ensureFocusRow(ctx, shiftedPomodoroAt, newPomodoro);
              await Session.fromStore(skip.copyWith(end: now)).save();
              await Session.resume(
                ctx,
                end: now.add(const Duration(minutes: 3)),
                pomodoro: newPomodoro,
                pomodoroAt: shiftedPomodoroAt,
                explicit: true,
              );
              return;
            }
          }
        }
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

    _emitOptimisticSession(
      ctx,
      pomodoro: pomodoro,
      pomodoroAt: now,
      now: now,
    );
    await _ensureFocusRow(ctx, now, pomodoro);
    await Session.resume(
      ctx,
      end: now.add(const Duration(minutes: 3)),
      pomodoro: pomodoro,
      pomodoroAt: now,
      explicit: true,
    );
  }

  /// Optimistic state update for [startSession]'s paths: synthesizes a
  /// `source='active'` session matching what `Session.resume` is about to
  /// persist and emits it immediately so the pill swaps from the Start
  /// button to the running ring without waiting for the DB write + Drift
  /// watcher to round-trip. The watcher's next emission overwrites this
  /// with the real saved row (same `pomodoroAt`/`pomodoro`, so the user
  /// sees no flicker).
  void _emitOptimisticSession(
    Priority ctx, {
    required Duration pomodoro,
    required DateTime pomodoroAt,
    required DateTime now,
  }) {
    if (state is! NowLoaded) return;
    final s = loadedState;
    final optimistic = Session(
      priority: ctx,
      end: now.add(const Duration(minutes: 3)),
      pomodoro: pomodoro,
      pomodoroAt: pomodoroAt,
      explicit: true,
    );
    emit(s.copyWith(session: optimistic, previewPomodoro: null));
  }

  /// Ensure a non-archived focus block row covers `[start, start + duration)`
  /// on [priority]. Reuses any existing covering row by extending its
  /// duration when needed; otherwise writes a fresh row. Idempotent for
  /// the common case where the scheduled row already matches.
  Future<void> _ensureFocusRow(
    Priority priority,
    DateTime start,
    Duration duration,
  ) async {
    if (state is! NowLoaded) return;
    final rows =
        (state as NowLoaded).priorityBlocksByPriority[priority.id] ??
        const <PriorityBlockRow>[];
    for (final r in rows) {
      if (r.archivedAt != null) continue;
      final d = r.duration;
      if (d == null || d <= Duration.zero) continue;
      if (!r.effectiveAt.isAfter(start) &&
          r.effectiveAt.add(d).isAfter(start)) {
        // Existing row covers `start`. Extend it if we'll outrun it.
        final coveringEnd = r.effectiveAt.add(d);
        final neededEnd = start.add(duration);
        if (neededEnd.isAfter(coveringEnd)) {
          await PriorityBlock.setBlockDuration(
            priorityId: priority.id,
            blockStart: r.effectiveAt,
            newDuration: neededEnd.difference(r.effectiveAt),
          );
        }
        return;
      }
    }
    // No covering row — create one at `start`.
    await PriorityBlock.setBlockDuration(
      priorityId: priority.id,
      blockStart: start,
      newDuration: duration,
    );
  }

  /// Soft-archive the non-archived focus block row that covers [moment]
  /// on [priority]. No-op if no such row exists. Used by Pause (so the
  /// agenda stops rendering the running block at its slot and shows the
  /// synthesized sliding `pausedFocus` block instead) and by Stop.
  Future<void> _archiveCoveringRow(Priority priority, DateTime moment) async {
    if (state is! NowLoaded) return;
    final rows =
        (state as NowLoaded).priorityBlocksByPriority[priority.id] ??
        const <PriorityBlockRow>[];
    for (final r in rows) {
      if (r.archivedAt != null) continue;
      final d = r.duration;
      if (d == null || d <= Duration.zero) continue;
      if (!r.effectiveAt.isAfter(moment) &&
          r.effectiveAt.add(d).isAfter(moment)) {
        await PriorityBlock.setBlockDuration(
          priorityId: priority.id,
          blockStart: r.effectiveAt,
          newDuration: null, // null → soft-archive in setBlockDuration
        );
        return;
      }
    }
  }

  /// Resolve a [PausedFocus] descriptor for [ctx], if any. Drives the
  /// agenda's sliding remaining-time block. Returns null when:
  ///   - the latest explicit session for [ctx] is not paused
  ///     (no paused-session row exists), or
  ///   - the computed remaining ≤ 0.
  Future<PausedFocus?> _resolvePausedFocus(Priority ctx) async {
    final paused = await Session.latestPausedFor(ctx.id);
    if (paused == null) return null;
    final pomo = paused.pomodoro;
    final pomoAt = paused.pomodoroAt;
    if (pomo == null || pomoAt == null) return null;
    final elapsed = paused.end.difference(pomoAt);
    final remaining = pomo - elapsed;
    if (remaining <= Duration.zero) return null;
    return PausedFocus(priority: ctx, remaining: remaining);
  }

  /// If [ctx] has a non-archived focus block row covering `now` and no
  /// active session for [ctx] exists, start one matched to the row's
  /// remaining window (`[now, effectiveAt + duration)`). Idempotent —
  /// safe to call from both [setContext] and [_onTrackTick].
  Future<void> _maybeAutoStart(Priority ctx) async {
    if (state is! NowLoaded) return;
    final s = loadedState;
    // Already running for this priority — no-op.
    if (s.pomodoroState != PomodoroState.inactive &&
        s.session?.priority?.id == ctx.id) {
      return;
    }
    final now = Time.now();
    final rows = s.priorityBlocksByPriority[ctx.id] ?? const [];
    for (final r in rows) {
      if (r.archivedAt != null) continue;
      final d = r.duration;
      if (d == null || d <= Duration.zero) continue;
      final end = r.effectiveAt.add(d);
      if (r.effectiveAt.isAfter(now) || !end.isAfter(now)) continue;
      // Covering row found — start the session for the remaining window.
      final remaining = end.difference(now);
      await startSession(override: remaining);
      return;
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
    final ctx = s.context;
    if (ctx != null) {
      await _archiveCoveringRow(ctx, Time.now());
    }
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
    final ctx = s.context;
    if (ctx != null) {
      await _archiveCoveringRow(ctx, now);
    }
  }

  /// Run [op] after any in-flight pomodoro adjustment finishes. Two
  /// rapid `+` presses arriving inside the same Drift-watcher tick
  /// would otherwise both read the same stale `state.session.pomodoro`
  /// and recompute the same target, dropping the second increment.
  /// Chaining lets the second op read the prior op's saved value off
  /// [_intendedPomodoro].
  Future<void> _runPomodoroOp(Future<void> Function() op) {
    final next = _pomodoroOpChain.then((_) => op());
    // Swallow errors on the chain tail so a single failure doesn't
    // poison subsequent ops. Callers still see the error on the
    // returned future.
    _pomodoroOpChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Baseline pomodoro for the next adjustment on [session]. Prefers
  /// the most recently saved value when it applies to the same session
  /// id, so chained presses compound through the watcher's async
  /// emission gap.
  Duration _baselineFor(Session session) {
    if (_intendedSessionId == session.id && _intendedPomodoro != null) {
      return _intendedPomodoro!;
    }
    return session.pomodoro!;
  }

  /// Adjust the pomodoro by [delta] (positive or negative). When a
  /// session is active and belongs to the context priority, the row's
  /// `pomodoro` field is mutated and saved. When inactive (or when the
  /// session is for a different priority), the change lands in
  /// [NowLoaded.previewPomodoro] which the pill renders.
  ///
  /// Both branches floor at [kMinPomodoro] and cap at `pomodoroEndCap − now`.
  Future<void> adjustPomodoro(Duration delta) =>
      _runPomodoroOp(() => _adjustPomodoro(delta));

  Future<void> _adjustPomodoro(Duration delta) async {
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
      final current = _baselineFor(session);
      final proposed = current + delta;
      final clamped = _clampPomodoro(ctx, proposed, anchor: session.pomodoroAt);
      if (clamped == current) return;
      _intendedPomodoro = clamped;
      _intendedSessionId = session.id;
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
  Future<void> decreasePomodoro() =>
      _runPomodoroOp(() => _decreasePomodoro());

  Future<void> _decreasePomodoro() async {
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
      final baseline = _baselineFor(session);
      final now = Time.now();
      final elapsed = now.difference(session.pomodoroAt!);
      final remaining = baseline - elapsed;
      final newRemaining = remaining > kPomodoroStep
          ? remaining - kPomodoroStep
          : kMinPomodoro;
      final clamped = _clampPomodoro(
        ctx,
        elapsed + newRemaining,
        anchor: session.pomodoroAt,
      );
      if (clamped == baseline) return;
      _intendedPomodoro = clamped;
      _intendedSessionId = session.id;
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
  Future<void> bumpPomodoroToNext15() =>
      _runPomodoroOp(() => _bumpPomodoroToNext15());

  Future<void> _bumpPomodoroToNext15() async {
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
      final baseline = _baselineFor(session);
      final now = Time.now();
      final end = session.pomodoroAt!.add(baseline);
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
      if (clamped == baseline && !promoteExplicit) return;
      _intendedPomodoro = clamped;
      _intendedSessionId = session.id;
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
/// because no row contributes." See [NowBloc.watchBlockDisplay] for
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
