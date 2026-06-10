import 'package:flutter_test/flutter_test.dart';
import 'package:plot/analytics/exception_throttle.dart';

void main() {
  final start = DateTime.utc(2026, 6, 10, 12);

  group('ExceptionThrottle', () {
    test('allows the first maxPerFingerprint identical errors', () {
      final throttle = ExceptionThrottle();
      for (var i = 0; i < ExceptionThrottle.defaultMaxPerFingerprint; i++) {
        expect(
          throttle.admit(StateError('boom'), start),
          isNotNull,
          reason: 'occurrence $i should be admitted',
        );
      }
    });

    test('suppresses identical errors beyond maxPerFingerprint', () {
      final throttle = ExceptionThrottle();
      for (var i = 0; i < ExceptionThrottle.defaultMaxPerFingerprint; i++) {
        throttle.admit(StateError('boom'), start);
      }
      // A crash loop: same error every frame.
      for (var i = 0; i < 100; i++) {
        expect(
          throttle.admit(
            StateError('boom'),
            start.add(Duration(milliseconds: 16 * i)),
          ),
          isNull,
        );
      }
    });

    test(
      'after resendInterval admits one heartbeat with suppressed_count',
      () {
        final throttle = ExceptionThrottle();
        for (var i = 0; i < ExceptionThrottle.defaultMaxPerFingerprint; i++) {
          throttle.admit(StateError('boom'), start);
        }
        for (var i = 0; i < 50; i++) {
          throttle.admit(StateError('boom'), start);
        }
        final later = start.add(ExceptionThrottle.defaultResendInterval);
        final props = throttle.admit(StateError('boom'), later);
        expect(props, isNotNull);
        expect(props!['suppressed_count'], 50);
        // And immediately suppressed again afterwards.
        expect(throttle.admit(StateError('boom'), later), isNull);
      },
    );

    test('tracks different fingerprints independently', () {
      final throttle = ExceptionThrottle();
      for (var i = 0; i < ExceptionThrottle.defaultMaxPerFingerprint; i++) {
        throttle.admit(StateError('boom'), start);
      }
      expect(throttle.admit(StateError('boom'), start), isNull);
      // Different message → different fingerprint → admitted.
      expect(throttle.admit(StateError('other failure'), start), isNotNull);
      // Same message, different type → different fingerprint → admitted.
      expect(throttle.admit(ArgumentError('boom'), start), isNotNull);
    });

    test('fingerprints on the first line of the error only', () {
      final throttle = ExceptionThrottle();
      for (var i = 0; i < ExceptionThrottle.defaultMaxPerFingerprint; i++) {
        throttle.admit(StateError('boom\ndetail $i'), start);
      }
      // Multi-line tail differs but first line matches → same fingerprint.
      expect(throttle.admit(StateError('boom\ndetail x'), start), isNull);
    });

    test('global cap suppresses floods of distinct errors', () {
      final throttle = ExceptionThrottle();
      var admitted = 0;
      // Pathological loop where the message varies every time (e.g. contains
      // a frame counter), defeating per-fingerprint throttling.
      for (var i = 0; i < 200; i++) {
        if (throttle.admit(StateError('boom $i'), start) != null) {
          admitted++;
        }
      }
      expect(admitted, ExceptionThrottle.defaultGlobalLimit);
    });

    test('global cap resets after the window passes', () {
      final throttle = ExceptionThrottle();
      for (var i = 0; i < ExceptionThrottle.defaultGlobalLimit; i++) {
        throttle.admit(StateError('boom $i'), start);
      }
      expect(throttle.admit(StateError('extra'), start), isNull);
      final later = start.add(ExceptionThrottle.defaultGlobalWindow);
      expect(throttle.admit(StateError('extra'), later), isNotNull);
    });
  });
}
