import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/thread.dart';

void main() {
  group('rsvpTargetsOccurrence', () {
    test('targets occurrence only with an existing, non-inherited occurrence RSVP', () {
      expect(
        rsvpTargetsOccurrence(
          hasExistingRsvp: true,
          occurrence: '2026-05-28',
          inheritedFromSeries: false,
        ),
        isTrue,
      );
    });

    test('targets the series when there is no existing RSVP', () {
      expect(
        rsvpTargetsOccurrence(
          hasExistingRsvp: false,
          occurrence: '2026-05-28',
          inheritedFromSeries: false,
        ),
        isFalse,
      );
    });

    test('targets the series when there is no occurrence', () {
      expect(
        rsvpTargetsOccurrence(
          hasExistingRsvp: true,
          occurrence: null,
          inheritedFromSeries: false,
        ),
        isFalse,
      );
    });

    test('targets the series when the RSVP was inherited from the series', () {
      expect(
        rsvpTargetsOccurrence(
          hasExistingRsvp: true,
          occurrence: '2026-05-28',
          inheritedFromSeries: true,
        ),
        isFalse,
      );
    });
  });
}
