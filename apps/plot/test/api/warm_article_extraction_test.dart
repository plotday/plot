import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/app_info.dart';
import 'package:plot/env.dart';

void main() {
  // warmArticleExtraction reads AppInfo.* and Env.apiRoot (both late final,
  // normally set by AppInfo.init()/Env.init()). Set them directly so the call
  // doesn't throw in a bare test; the session-token lookup already returns
  // null gracefully when uninitialized.
  setUpAll(() {
    AppInfo.version = 'test';
    AppInfo.buildNumber = '0';
    AppInfo.platform = 'test';
    Env.apiRoot = 'https://api.test/app';
  });

  tearDown(() => api.debugSetHttpClientFactory(http.Client.new));

  test('warmArticleExtraction POSTs the url to /extract', () async {
    final captured = <http.Request>[];
    api.debugSetHttpClientFactory(
      () => MockClient((request) async {
        captured.add(request);
        return http.Response('{"status":"pending"}', 200);
      }),
    );

    await api.warmArticleExtraction('https://example.com/a');

    expect(captured, hasLength(1));
    expect(captured.single.method, 'POST');
    expect(captured.single.url.path, endsWith('/extract'));
    expect(
      jsonDecode(captured.single.body),
      equals({'url': 'https://example.com/a'}),
    );
  });

  test('warmArticleExtraction swallows a server error', () async {
    api.debugSetHttpClientFactory(
      () => MockClient((_) async => http.Response('boom', 500)),
    );
    // Must not throw.
    await api.warmArticleExtraction('https://example.com/a');
  });

  test('warmArticleExtraction swallows a thrown client exception', () async {
    api.debugSetHttpClientFactory(
      () => MockClient((_) async => throw http.ClientException('offline')),
    );
    // Must not throw even when the HTTP client itself fails.
    await api.warmArticleExtraction('https://example.com/a');
  });
}
