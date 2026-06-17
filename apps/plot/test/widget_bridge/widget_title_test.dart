import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_title.dart';

void main() {
  final now = DateTime(2026, 6, 17, 9, 0);

  WidgetTitle call({
    String? focusLabel = 'Marketing',
    String? currentEventTitle,
    DateTime? currentEventStart,
    DateTime? currentEventEnd,
    String? nextEventTitle,
    DateTime? nextEventStart,
    bool sessionTimerRunning = false,
  }) =>
      computeWidgetTitle(
        focusLabel: focusLabel,
        currentEventTitle: currentEventTitle,
        currentEventStart: currentEventStart,
        currentEventEnd: currentEventEnd,
        nextEventTitle: nextEventTitle,
        nextEventStart: nextEventStart,
        sessionTimerRunning: sessionTimerRunning,
        now: now,
      );

  test('imminent event within 2 min wins, ceil minutes', () {
    final t = call(
      nextEventTitle: 'Standup',
      nextEventStart: now.add(const Duration(seconds: 90)),
    );
    expect(t.text, '2m → Standup');
    expect(t.isTimer, false);
  });

  test('event >2 min away does not trigger state 1', () {
    final t = call(
      nextEventTitle: 'Standup',
      nextEventStart: now.add(const Duration(minutes: 25)),
    );
    expect(t.text, 'Marketing'); // falls to focus
  });

  test('in-progress event beats running timer', () {
    final t = call(
      currentEventTitle: 'Design review',
      currentEventStart: now.subtract(const Duration(minutes: 5)),
      currentEventEnd: now.add(const Duration(minutes: 25)),
      sessionTimerRunning: true,
    );
    expect(t.text, 'Design review');
    expect(t.isTimer, false);
  });

  test('running timer with no event → timer prefix is focus', () {
    final t = call(sessionTimerRunning: true);
    expect(t.isTimer, true);
    expect(t.timerPrefix, 'Marketing');
    expect(t.text, isNull);
  });

  test('nothing active → focus label', () {
    expect(call().text, 'Marketing');
  });

  test('next event on a different day is ignored', () {
    final t = call(
      nextEventTitle: 'Tomorrow kickoff',
      nextEventStart: now.add(const Duration(days: 1)),
    );
    expect(t.text, 'Marketing');
  });
}
