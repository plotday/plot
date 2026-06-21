import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/auth/sign_in_retry.dart';

/// Records the durations passed to it and never actually waits, so retry
/// tests run instantly while still asserting the backoff schedule.
class _RecordingDelay {
  final List<Duration> waits = [];
  Future<void> call(Duration d) async {
    waits.add(d);
  }
}

ApiException _api(int statusCode) => ApiException(
  statusCode: statusCode,
  endpoint: '/activate',
  title: 'err',
  description: 'err',
);

void main() {
  group('retryAsync', () {
    test(
      'returns the first result without retrying or waiting on success',
      () async {
        var calls = 0;
        final delay = _RecordingDelay();

        final result = await retryAsync(
          () async {
            calls++;
            return 'ok';
          },
          isRetryable: (_) => true,
          delay: delay.call,
        );

        expect(result, 'ok');
        expect(calls, 1);
        expect(delay.waits, isEmpty);
      },
    );

    test('retries a retryable failure and returns once it succeeds', () async {
      var calls = 0;
      final delay = _RecordingDelay();

      final result = await retryAsync(
        () async {
          calls++;
          if (calls < 3) throw TimeoutException('slow');
          return 'ok';
        },
        maxAttempts: 3,
        isRetryable: isTransientSignInError,
        backoff: (attempt) => Duration(seconds: attempt),
        delay: delay.call,
      );

      expect(result, 'ok');
      expect(calls, 3);
      // Waited after attempt 1 and attempt 2, not after the success.
      expect(delay.waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
    });

    test('rethrows the last error after exhausting maxAttempts', () async {
      var calls = 0;
      final delay = _RecordingDelay();

      await expectLater(
        retryAsync(
          () async {
            calls++;
            throw TimeoutException('attempt $calls');
          },
          maxAttempts: 3,
          isRetryable: isTransientSignInError,
          delay: delay.call,
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(calls, 3);
      // Waited between attempts only (2 gaps for 3 attempts).
      expect(delay.waits.length, 2);
    });

    test('does not retry a non-retryable error', () async {
      var calls = 0;
      final delay = _RecordingDelay();

      await expectLater(
        retryAsync(
          () async {
            calls++;
            throw _api(400);
          },
          maxAttempts: 3,
          isRetryable: isTransientSignInError,
          delay: delay.call,
        ),
        throwsA(isA<ApiException>()),
      );

      expect(calls, 1);
      expect(delay.waits, isEmpty);
    });
  });

  group('isTransientSignInError', () {
    test('TimeoutException is transient', () {
      expect(isTransientSignInError(TimeoutException('x')), isTrue);
    });

    test('NetworkException is transient', () {
      expect(isTransientSignInError(const NetworkException()), isTrue);
    });

    test('IdentityResolutionException is transient', () {
      expect(
        isTransientSignInError(const IdentityResolutionException('x')),
        isTrue,
      );
    });

    test('5xx ApiException is transient', () {
      expect(isTransientSignInError(_api(503)), isTrue);
      expect(isTransientSignInError(_api(500)), isTrue);
    });

    test('4xx ApiException is not transient', () {
      expect(isTransientSignInError(_api(400)), isFalse);
      expect(isTransientSignInError(_api(401)), isFalse);
      expect(isTransientSignInError(_api(409)), isFalse);
    });

    test('an arbitrary error is not transient', () {
      expect(isTransientSignInError(StateError('nope')), isFalse);
      expect(isTransientSignInError(Exception('nope')), isFalse);
    });
  });
}
