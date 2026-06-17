import 'package:equatable/equatable.dart';

class WidgetTodo extends Equatable {
  const WidgetTodo({required this.threadId, required this.title});
  final String threadId;
  final String title;
  Map<String, Object?> toJson() => {'threadId': threadId, 'title': title};
  @override
  List<Object?> get props => [threadId, title];
}

class WidgetFocus extends Equatable {
  const WidgetFocus({
    required this.focusId,
    required this.roleName,
    required this.focusName,
    required this.colorHex,
  });
  final String focusId;
  final String? roleName;
  final String focusName;
  final String? colorHex;
  Map<String, Object?> toJson() => {
        'focusId': focusId,
        'roleName': roleName,
        'focusName': focusName,
        'colorHex': colorHex,
      };
  @override
  List<Object?> get props => [focusId, roleName, focusName, colorHex];
}

class WidgetEvent extends Equatable {
  const WidgetEvent({
    required this.threadId,
    required this.title,
    required this.startIso,
    required this.endIso,
    required this.hasCall,
  });
  final String threadId;
  final String title;
  final String startIso;
  final String? endIso;
  final bool hasCall;
  Map<String, Object?> toJson() => {
        'threadId': threadId,
        'title': title,
        'startIso': startIso,
        'endIso': endIso,
        'hasCall': hasCall,
      };
  @override
  List<Object?> get props => [threadId, title, startIso, endIso, hasCall];
}

/// Snapshot of the data exposed to native widgets and menubar/tray
/// surfaces. Written to platform shared storage so widget extensions
/// can read it during their own refresh cycles without invoking
/// Flutter.
///
/// The shape is intentionally minimal — only fields a widget could
/// plausibly render. Add new fields here when widget designs require
/// them; native readers tolerate missing keys.
class WidgetState extends Equatable {
  const WidgetState({
    required this.isSignedIn,
    this.userId,
    this.currentPriorityId,
    this.currentPriorityTitle,
    this.currentEventTitle,
    this.timerState = 'inactive',
    this.timerSource,
    this.timerEndsAtIso,
    this.nextEventTitle,
    this.nextEventStartIso,
    this.canStart = false,
    this.canPause = false,
    this.canStop = false,
    this.canAddTime = false,
    this.canRemoveTime = false,
    this.title,
    this.titleIsTimer = false,
    this.timerTitlePrefix,
    this.currentFocus,
    this.currentEvent2,
    this.nextEvent2,
    this.todos = const [],
    this.focuses = const [],
  });

  factory WidgetState.signedOut() => const WidgetState(isSignedIn: false);

  final bool isSignedIn;
  final String? userId;
  final String? currentPriorityId;
  final String? currentPriorityTitle;

  /// Title of the user-selected event from the agenda, mirroring the
  /// unified header. Null when no event is selected.
  final String? currentEventTitle;

  /// One of: `'inactive'`, `'running'`. We don't model a distinct
  /// `'paused'` state because the in-app pill conflates pause with
  /// inactive — pressing Start after a pause auto-resumes the existing
  /// pomodoro session via `NowBloc.startSession`.
  final String timerState;

  /// `'session'` (manual pomodoro) or `'event'` (auto-displayed
  /// scheduled event). Null when [timerState] is `'inactive'`.
  final String? timerSource;

  /// Wall-clock end of the active timer, ISO 8601. Native code ticks a
  /// MM:SS countdown from this without further IPC.
  final String? timerEndsAtIso;

  /// Title of the next scheduled event (across all priorities) whose
  /// start is in the future. Always paired with [nextEventStartIso] —
  /// native code applies the "≤ 10m until start" threshold so the
  /// approaching-event banner ticks down without needing another push.
  final String? nextEventTitle;

  /// UTC ISO 8601 start of [nextEventTitle]. Null when no future event
  /// is on today's agenda.
  final String? nextEventStartIso;

  final bool canStart;
  final bool canPause;
  final bool canStop;
  final bool canAddTime;
  final bool canRemoveTime;

  /// Fully-composed menu-bar/tray title string for the non-timer states.
  /// Null when signed out / nothing to show. See widget_title.dart.
  final String? title;

  /// When true, the title is the running-timer state: native renders
  /// "$timerTitlePrefix · {ticking remaining}" instead of [title].
  final bool titleIsTimer;

  /// Focus label shown before the ticking countdown when [titleIsTimer].
  final String? timerTitlePrefix;

  final WidgetFocus? currentFocus;
  final WidgetEvent? currentEvent2;
  final WidgetEvent? nextEvent2;
  final List<WidgetTodo> todos;
  final List<WidgetFocus> focuses;

  Map<String, Object?> toJson() => {
    'isSignedIn': isSignedIn,
    'userId': userId,
    'currentPriorityId': currentPriorityId,
    'currentPriorityTitle': currentPriorityTitle,
    'currentEventTitle': currentEventTitle,
    'timerState': timerState,
    'timerSource': timerSource,
    'timerEndsAtIso': timerEndsAtIso,
    'nextEventTitle': nextEventTitle,
    'nextEventStartIso': nextEventStartIso,
    'canStart': canStart,
    'canPause': canPause,
    'canStop': canStop,
    'canAddTime': canAddTime,
    'canRemoveTime': canRemoveTime,
    'title': title,
    'titleIsTimer': titleIsTimer,
    'timerTitlePrefix': timerTitlePrefix,
    'currentFocus': currentFocus?.toJson(),
    'currentEvent2': currentEvent2?.toJson(),
    'nextEvent2': nextEvent2?.toJson(),
    'todos': todos.map((t) => t.toJson()).toList(),
    'focuses': focuses.map((f) => f.toJson()).toList(),
  };

  @override
  List<Object?> get props => [
    isSignedIn,
    userId,
    currentPriorityId,
    currentPriorityTitle,
    currentEventTitle,
    timerState,
    timerSource,
    timerEndsAtIso,
    nextEventTitle,
    nextEventStartIso,
    canStart,
    canPause,
    canStop,
    canAddTime,
    canRemoveTime,
    title,
    titleIsTimer,
    timerTitlePrefix,
    currentFocus,
    currentEvent2,
    nextEvent2,
    todos,
    focuses,
  ];
}
