import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/user.dart';
import 'package:plot/store/store.dart';

import 'widget_bridge_channel.dart';
import 'widget_data.dart';
import 'widget_navigation.dart';
import 'widget_title.dart';

/// Map already-fetched (id, title) pairs into ≤5 to-do rows.
List<WidgetTodo> todoRowsFrom(List<({String id, String title})> rows) =>
    [for (final r in rows.take(5)) WidgetTodo(threadId: r.id, title: r.title)];

/// Role-gated focus label mirroring [FocusLabel]: show "$role › $focus" only
/// when the user has 2+ roles and the focus has a role. Separator matches
/// `Priority.separator`.
String focusLabelFor(String focusTitle, String? roleName, int roleCount) {
  if (roleName != null && roleCount >= 2) {
    return '$roleName › $focusTitle';
  }
  return focusTitle;
}

/// Converts a [Thread] to a [WidgetEvent], or null when the thread is null
/// or has no start time.
WidgetEvent? widgetEventFrom(Thread? thread, {required bool hasCall}) {
  if (thread == null) return null;
  final start = thread.at?.start;
  if (start == null) return null;
  return WidgetEvent(
    threadId: thread.id.toShortString(),
    title: thread.displayTitle,
    startIso: start.toUtc().toIso8601String(),
    endIso: thread.at?.end?.toUtc().toIso8601String(),
    hasCall: hasCall,
  );
}

bool _isSameLocalDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

/// Routes the navigation/window actions through [navigator]. Returns true if
/// the action was one of them. Data actions (setCurrentFocus, joinCall,
/// capture) are handled in WidgetBridge where bloc/state is available.
Future<bool> routeWidgetActionForTest({
  required WidgetNavigator navigator,
  required String name,
  required Map<String, Object?> args,
}) async {
  switch (name) {
    case widgetActionOpenApp:
      await navigator.showWindow();
      return true;
    case widgetActionNavigateThread:
      final threadId = args['threadId'];
      final priorityId = args['priorityId'];
      if (threadId is String && priorityId is String) {
        await navigator.openThread(threadId, priorityId);
      }
      return true;
    case widgetActionNavigateFocus:
      final priorityId = args['priorityId'];
      if (priorityId is String) await navigator.openFocus(priorityId);
      return true;
  }
  return false;
}

/// Side-effect listener that watches the user/now blocs and pushes
/// a fresh [WidgetState] to the native widget host whenever the
/// signed-in user, context priority, or active timer changes.
///
/// The bridge intentionally does not own any UI — it only translates
/// app state into the data widgets read on their own refresh
/// timeline. Callers attach it once at app startup (see
/// `RootProvider`) and dispose it on tear-down.
class WidgetBridge {
  WidgetBridge({
    required UserBloc userBloc,
    required NowBloc nowBloc,
    WidgetNavigator navigator = const DefaultWidgetNavigator(),
  })  :
        // ignore: prefer_initializing_formals
        _userBloc = userBloc,
        // ignore: prefer_initializing_formals
        _nowBloc = nowBloc,
        // ignore: prefer_initializing_formals
        _navigator = navigator;

  final UserBloc _userBloc;
  final NowBloc _nowBloc;
  final WidgetNavigator _navigator;

  StreamSubscription<UserState>? _userSub;
  StreamSubscription<NowState>? _nowSub;
  Timer? _debounce;
  WidgetState _last = WidgetState.signedOut();
  bool _started = false;

  // event-thread-id (base58 short string) -> link subscription,
  // for the at-most-two events we surface
  final Map<String, StreamSubscription<List<Link>>> _eventLinkSubs = {};

  List<WidgetTodo> _todos = const [];
  StreamSubscription<ThreadWatchResult>? _todoSub;
  PriorityId? _todoPriorityId;

  void _syncTodoWatch(PriorityId? priorityId) {
    if (priorityId == _todoPriorityId) return;
    _todoPriorityId = priorityId;
    unawaited(_todoSub?.cancel());
    _todos = const [];
    if (priorityId == null) return;
    _todoSub = Thread.watch(
      priorityId: priorityId,
      todoOnly: true,
      archived: false,
      order: ThreadOrder.sorted,
      limit: 5,
    ).listen(
      (result) {
        _todos = todoRowsFrom([
          for (final t in result.threads)
            (id: t.id.toShortString(), title: t.displayTitle),
        ]);
        _scheduleSync();
      },
      onError: (Object error, StackTrace stackTrace) {
        Tracker.captureException(error, stackTrace);
      },
    );
  }

  // Keyed by base58 short string — same format used in WidgetEvent.threadId
  // and the snapshot lookup below.
  final Set<String> _eventThreadIdsWithCall = {};

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
    for (final sub in _eventLinkSubs.values) {
      await sub.cancel();
    }
    _eventLinkSubs.clear();
    _eventThreadIdsWithCall.clear();
    await _todoSub?.cancel();
    _todoSub = null;
    _todoPriorityId = null;
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

  /// Re-subscribes to [Link.watchForThread] for the given event thread ids,
  /// dropping subscriptions for threads no longer surfaced and adding new ones.
  /// The listener updates [_eventThreadIdsWithCall] (keyed by base58 short
  /// string) and triggers a re-sync when call presence changes.
  void _syncEventLinkWatches(Iterable<Thread> eventThreads) {
    final wanted = {for (final t in eventThreads) t.id.toShortString(): t};
    // Drop stale subscriptions.
    for (final id in _eventLinkSubs.keys.toList()) {
      if (!wanted.containsKey(id)) {
        unawaited(_eventLinkSubs.remove(id)!.cancel());
        _eventThreadIdsWithCall.remove(id);
      }
    }
    // Add new subscriptions.
    for (final entry in wanted.entries) {
      final id = entry.key;
      final thread = entry.value;
      if (_eventLinkSubs.containsKey(id)) continue;
      _eventLinkSubs[id] = Link.watchForThread(thread.id).listen(
        (links) {
          final primary = Thread.primaryLink(links);
          final hasCall =
              primary != null &&
              (primary.actions ?? const <UserAction>[])
                  .whereType<ConferencingUserAction>()
                  .isNotEmpty;
          final changed = hasCall
              ? _eventThreadIdsWithCall.add(id)
              : _eventThreadIdsWithCall.remove(id);
          if (changed) _scheduleSync();
        },
        onError: (Object error, StackTrace stackTrace) {
          Tracker.captureException(error, stackTrace);
        },
      );
    }
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

    // ----- New fields: focus, events, title -----

    final roleCount = Role.cachedCount;
    final roleName = Role.fromCache(priority.roleId)?.name;
    final focusLabel = focusLabelFor(priority.title, roleName, roleCount);

    final inProgress = nowState.inProgressEventForContext;
    final nowLocal = Time.now();

    // `todayUpcoming` is non-null only when the first upcoming event starts
    // today, so all downstream code can work with it without null-safety
    // gymnastics.
    final Thread? todayUpcoming = () {
      if (upcoming.isEmpty) return null;
      final first = upcoming.first;
      final start = first.at?.start;
      if (start == null) return null;
      return _isSameLocalDay(start, nowLocal) ? first : null;
    }();

    final currentEvent2 = widgetEventFrom(
      inProgress,
      hasCall: inProgress != null &&
          _eventThreadIdsWithCall.contains(inProgress.id.toShortString()),
    );
    final nextEvent2 = widgetEventFrom(
      todayUpcoming,
      hasCall: todayUpcoming != null &&
          _eventThreadIdsWithCall.contains(todayUpcoming.id.toShortString()),
    );

    // Keep link watches in sync with the at-most-two events we surface.
    _syncEventLinkWatches([
      ?inProgress,
      ?todayUpcoming,
    ]);

    // Keep todo watch in sync with the current focus.
    _syncTodoWatch(priority.id);

    final widgetTitle = computeWidgetTitle(
      focusLabel: focusLabel,
      currentEventTitle: currentEvent2?.title,
      currentEventStart: inProgress?.at?.start,
      currentEventEnd: inProgress?.at?.end,
      nextEventTitle: nextEvent2?.title,
      nextEventStart: todayUpcoming?.at?.start,
      sessionTimerRunning: timerSource == 'session',
      now: nowLocal,
    );

    final currentFocus = WidgetFocus(
      focusId: priority.id.toShortString(),
      roleName: (roleCount >= 2) ? roleName : null,
      focusName: priority.title,
      colorHex: null, // deferred: needs BuildContext for ThemeColor→sRGB
    );

    final focuses = <WidgetFocus>[
      for (final p in nowState.priorities)
        if (!p.isFyi)
          WidgetFocus(
            focusId: p.id.toShortString(),
            roleName: (roleCount >= 2) ? Role.fromCache(p.roleId)?.name : null,
            focusName: p.title,
            colorHex: null, // deferred: needs BuildContext for ThemeColor→sRGB
          ),
    ];

    return WidgetState(
      isSignedIn: true,
      userId: user.id,
      currentPriorityId: priority.id.toShortString(),
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
      title: widgetTitle.text,
      titleIsTimer: widgetTitle.isTimer,
      timerTitlePrefix: widgetTitle.timerPrefix,
      currentFocus: currentFocus,
      currentEvent2: currentEvent2,
      nextEvent2: nextEvent2,
      todos: _todos,
      focuses: focuses,
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
    // Navigation/window actions are delegated to the navigator.
    if (await routeWidgetActionForTest(
      navigator: _navigator,
      name: name,
      args: args,
    )) {
      return null;
    }
    switch (name) {
      case widgetActionSetCurrentFocus:
        final id = args['focusId'];
        final state = _nowBloc.state;
        if (id is String && state is NowLoaded) {
          Priority? match;
          for (final p in state.priorities) {
            if (p.id.toShortString() == id) {
              match = p;
              break;
            }
          }
          if (match != null) _nowBloc.setContext(match);
        }
        return null;
      case widgetActionJoinCall:
        await _joinCall(args['threadId']);
        return null;
      case widgetActionCapture:
        await _capture(
          args['text'] as String? ?? '',
          args['target'] as String? ?? 'newThreadInCurrentFocus',
          asTodo: args['asTodo'] == true,
        );
        return null;
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

  /// Resolves the conferencing URL from the event thread's primary link and
  /// opens it in an external browser/app. Mirrors the join-meeting button in
  /// `lib/widget/primary_link_header_actions.dart`.
  Future<void> _joinCall(Object? threadIdArg) async {
    if (threadIdArg is! String) return;
    try {
      final id = Uuid.tryFromShortString(threadIdArg);
      if (id == null) return;
      final links = await Link.watchForThread(id).first;
      final primary = Thread.primaryLink(links);
      if (primary == null) return;
      final action = (primary.actions ?? const <UserAction>[])
          .whereType<ConferencingUserAction>()
          .firstOrNull;
      if (action == null) return;
      final uri = Uri.tryParse(action.url);
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error, stackTrace) {
      Tracker.captureException(error, stackTrace);
    }
  }

  /// Persists captured text from the menu-bar/tray quick-capture field.
  ///
  /// When [target] is `'currentEventThread'`, appends a note to the in-progress
  /// event thread for the current focus.
  /// Otherwise (`'newThreadInCurrentFocus'`), creates a new thread+note in the
  /// current focus priority.
  ///
  /// When [asTodo] is true a new thread is created as an active to-do
  /// (`Thread.active = true`, the app's "Doing" state). [asTodo] applies to the
  /// new-thread path; appending a note to an existing event thread ignores it.
  ///
  /// Both paths use direct Store saves (no BuildContext required) so they work
  /// headlessly from the menu-bar handler. The Thread factory and Note.draft
  /// follow the same conventions as the in-app compose flow.
  Future<void> _capture(
    String text,
    String target, {
    bool asTodo = false,
  }) async {
    if (text.isEmpty) return;
    try {
      final nowState = _nowBloc.state;
      if (nowState is! NowLoaded) return;

      // A to-do is a standalone actionable thread, so when the user marks the
      // capture as a to-do we always create a new active thread (even if an
      // event is in progress) rather than appending a note to the event.
      if (target == 'currentEventThread' && !asTodo) {
        // Append note to the in-progress event thread.
        final eventThread = nowState.inProgressEventForContext;
        if (eventThread == null) {
          // Fall back to new thread in focus when no event is in progress.
          await _captureNewThread(text, nowState, asTodo: asTodo);
          return;
        }
        final note = Note.draft(threadId: eventThread.id).copyWith(
          content: text,
          draft: false,
        );
        await note.save();
      } else {
        await _captureNewThread(text, nowState, asTodo: asTodo);
      }
    } catch (error, stackTrace) {
      Tracker.captureException(error, stackTrace);
    }
  }

  /// Creates a new thread with [text] as its first note in the current focus.
  /// When [asTodo] is true BOTH the thread and the note are marked as the
  /// user's to-do, mirroring the in-app commands: the thread via
  /// `copyWith(todo: true)` (as `ToggleThreadActive` does) and the note via
  /// `toggleTag(Tag.todo, …)` (as `ToggleSelfTask` does).
  Future<void> _captureNewThread(
    String text,
    NowLoaded nowState, {
    bool asTodo = false,
  }) async {
    final ctx = nowState.context ?? nowState.defaultPriority;
    // Thread factory defaults draft=false and sets activityRemoteDirty=true
    // so save() will push to the server.
    final thread = Thread(
      priority: ctx,
      preview: Thread.createPreviewFromMarkdown(text),
    );
    await thread.save();

    var note = Note.draft(threadId: thread.id).copyWith(
      content: text,
      draft: false,
    );
    if (asTodo) {
      note = note.toggleTag(Tag.todo, Base.actorId);
    }
    await note.save();

    if (asTodo) {
      // Mark the thread itself as a to-do (the "Doing" state) via the same
      // path ToggleThreadActive uses, so it surfaces in the to-do list.
      await thread.copyWith(todo: true).save();
    }
  }
}
