import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';

void main() {
  ApiException api(int status) => ApiException(
        statusCode: status,
        endpoint: '/sync/threads',
        title: 't',
        description: 'd',
      );

  group('pushBackoffDelay', () {
    test('no cooldown before the first failure', () {
      expect(Store.pushBackoffDelay(0), Duration.zero);
    });

    test('grows exponentially with consecutive failures', () {
      expect(Store.pushBackoffDelay(1), const Duration(seconds: 5));
      expect(Store.pushBackoffDelay(2), const Duration(seconds: 10));
      expect(Store.pushBackoffDelay(3), const Duration(seconds: 20));
      expect(Store.pushBackoffDelay(4), const Duration(seconds: 40));
    });

    test('caps at five minutes so a long outage still retries periodically', () {
      expect(Store.pushBackoffDelay(20), const Duration(seconds: 300));
      // Very large counts must not overflow the bit-shift into a bogus value.
      expect(Store.pushBackoffDelay(1000), const Duration(seconds: 300));
    });
  });

  group('isTransientPushError', () {
    test('server overload / timeout statuses back off instead of fanning out',
        () {
      // A 30s statement_timeout surfaces as 500, and 502/503/429/408 are all
      // "server is struggling" — fanning out into N individual 30s requests
      // only hammers it harder, so these must back off.
      expect(Store.isTransientPushError(api(500)), isTrue);
      expect(Store.isTransientPushError(api(503)), isTrue);
      expect(Store.isTransientPushError(api(429)), isTrue);
      expect(Store.isTransientPushError(api(408)), isTrue);
    });

    test('a request timeout / network drop backs off', () {
      expect(Store.isTransientPushError(const NetworkException()), isTrue);
    });

    test('permanent data rejections are not transient (fan out to isolate)',
        () {
      expect(Store.isTransientPushError(api(400)), isFalse);
      expect(Store.isTransientPushError(api(409)), isFalse);
      expect(Store.isTransientPushError(api(422)), isFalse);
    });

    test('auth errors are handled separately, not as transient backoff', () {
      expect(Store.isTransientPushError(api(401)), isFalse);
    });
  });
}
