import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plot/api/api.dart' as api;

/// Wraps a client and records whether [close] has been called, so tests can
/// assert the failed shared client is not force-closed while sibling
/// requests may still be in flight.
class _CloseRecordingClient extends http.BaseClient {
  _CloseRecordingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// The shared keep-alive client: a ClientException (stale socket after
/// backgrounding) recreates the client; idempotent sends retry once on the
/// fresh client, mutating sends surface the error unchanged.
void main() {
  tearDown(() => api.debugSetHttpClientFactory(http.Client.new));

  /// First client throws ClientException on use; every later client
  /// responds 200. Returns the call counter.
  List<int> installFlakyFactory() {
    final counts = [0];
    var clientIndex = -1;
    api.debugSetHttpClientFactory(() {
      clientIndex++;
      final failing = clientIndex == 0;
      return MockClient((request) async {
        counts[0]++;
        if (failing) throw http.ClientException('stale socket');
        return http.Response('ok', 200);
      });
    });
    return counts;
  }

  test('idempotent send retries once on a fresh client', () async {
    final counts = installFlakyFactory();
    final response = await api.sendWithReconnect(
      (client) => client.get(Uri.parse('https://example.test/x')),
      idempotent: true,
    );
    expect(response.statusCode, 200);
    expect(counts[0], 2, reason: 'failed once, retried once');
  });

  test('mutating send surfaces ClientException without retry', () async {
    final counts = installFlakyFactory();
    await expectLater(
      api.sendWithReconnect(
        (client) => client.post(Uri.parse('https://example.test/x')),
        idempotent: false,
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(counts[0], 1, reason: 'no retry for mutating requests');
  });

  test('client is reused across sends (no per-call client)', () async {
    var created = 0;
    api.debugSetHttpClientFactory(() {
      created++;
      return MockClient((request) async => http.Response('ok', 200));
    });
    for (var i = 0; i < 3; i++) {
      await api.sendWithReconnect(
        (client) => client.get(Uri.parse('https://example.test/$i')),
        idempotent: true,
      );
    }
    expect(created, 1, reason: 'one shared client for all three sends');
  });

  test('concurrent failures recreate the client exactly once', () async {
    var created = 0;
    var blockedCalls = 0;
    final gate = Completer<void>();
    api.debugSetHttpClientFactory(() {
      created++;
      final failing = created == 1;
      return MockClient((request) async {
        if (failing) {
          blockedCalls++;
          await gate.future;
          throw http.ClientException('stale socket');
        }
        return http.Response('ok', 200);
      });
    });

    // Start two sends that both hit the first (doomed) client and park on
    // the gate, then release them so both observe the ClientException.
    final futures = [
      api.sendWithReconnect(
        (client) => client.get(Uri.parse('https://example.test/a')),
        idempotent: true,
      ),
      api.sendWithReconnect(
        (client) => client.get(Uri.parse('https://example.test/b')),
        idempotent: true,
      ),
    ];
    while (blockedCalls < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    gate.complete();

    final responses = await Future.wait(futures);
    expect(responses.map((r) => r.statusCode), everyElement(200),
        reason: 'both idempotent sends succeed on the recreated client');
    expect(created, 2,
        reason: 'initial client + one recreation — the identical-guard '
            'prevents the second failure from recreating again');
  });

  test('failed client is not closed synchronously (deferred close)', () async {
    _CloseRecordingClient? failedClient;
    var created = 0;
    api.debugSetHttpClientFactory(() {
      created++;
      if (created == 1) {
        return failedClient = _CloseRecordingClient(
          MockClient((request) async {
            throw http.ClientException('stale socket');
          }),
        );
      }
      return MockClient((request) async => http.Response('ok', 200));
    });

    final response = await api.sendWithReconnect(
      (client) => client.get(Uri.parse('https://example.test/x')),
      idempotent: true,
    );
    expect(response.statusCode, 200);
    expect(created, 2, reason: 'recovery recreated the client');
    expect(failedClient!.closed, isFalse,
        reason: 'close is deferred (Timer) so in-flight sibling requests on '
            'the old client are not force-aborted');
  });
}
