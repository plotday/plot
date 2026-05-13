import 'package:equatable/equatable.dart';

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
  ];
}
