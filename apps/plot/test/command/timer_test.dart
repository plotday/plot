import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/timer.dart';

void main() {
  group('Timer command titles', () {
    test('StartTimer title is "Start focus"', () {
      expect(StartTimer().title, 'Start focus');
    });

    test('StopTimer title is "Pause focus"', () {
      expect(StopTimer().title, 'Pause focus');
    });

    test('EndTimer title is "Stop focus"', () {
      expect(EndTimer().title, 'Stop focus');
    });
  });
}
