import 'package:equatable/equatable.dart';

/// Result of [computeWidgetTitle]. When [isTimer] is true the native shell
/// renders "$timerPrefix · {ticking remaining}"; otherwise it renders [text].
class WidgetTitle extends Equatable {
  const WidgetTitle({this.text, this.isTimer = false, this.timerPrefix});
  final String? text;
  final bool isTimer;
  final String? timerPrefix;
  @override
  List<Object?> get props => [text, isTimer, timerPrefix];
}

/// Pure menu-bar/tray title precedence. See the redesign spec, "Always-visible
/// title". Computed in Dart so both native shells render identically.
WidgetTitle computeWidgetTitle({
  required String? focusLabel,
  required String? currentEventTitle,
  required DateTime? currentEventStart,
  required DateTime? currentEventEnd,
  required String? nextEventTitle,
  required DateTime? nextEventStart,
  required bool sessionTimerRunning,
  required DateTime now,
}) {
  // State 1: next event today, starting within 2 minutes.
  if (nextEventTitle != null &&
      nextEventStart != null &&
      _isSameLocalDay(nextEventStart, now)) {
    final until = nextEventStart.difference(now);
    if (until > Duration.zero && until <= const Duration(minutes: 2)) {
      final mins = (until.inSeconds / 60).ceil();
      return WidgetTitle(text: '${mins}m → $nextEventTitle');
    }
  }

  // State 2: current event in progress.
  if (currentEventTitle != null &&
      currentEventStart != null &&
      !now.isBefore(currentEventStart) &&
      (currentEventEnd == null || now.isBefore(currentEventEnd))) {
    return WidgetTitle(text: currentEventTitle);
  }

  // State 3: a manual focus timer is running.
  if (sessionTimerRunning) {
    return WidgetTitle(isTimer: true, timerPrefix: focusLabel);
  }

  // State 4: current focus.
  return WidgetTitle(text: focusLabel);
}

bool _isSameLocalDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}
