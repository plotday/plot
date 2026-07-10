import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/app_info.dart';
import 'package:plot/env.dart';
import 'package:plot/store/store.dart';

/// Proves that `Thread.searchRemote` forwards the active header filter chips to
/// `GET /sync/threads/search` and — crucially for the "browse by thread type
/// with no text" bug — that it fires the request even when the text query is
/// empty, as long as a filter is active.
///
/// `Thread.searchRemote` short-circuits and returns before touching the local
/// Drift store when the server responds with an empty list, so a `[]` mock
/// keeps these tests free of any database bootstrap.
void main() {
  setUpAll(() {
    // searchRemote → api.get reads AppInfo.* and Env.apiRoot (late final,
    // normally set by init()). Set them directly; the session-token lookup
    // returns null gracefully when uninitialized.
    AppInfo.version = 'test';
    AppInfo.buildNumber = '0';
    AppInfo.platform = 'test';
    Env.apiRoot = 'https://api.test/app';
  });

  tearDown(() => api.debugSetHttpClientFactory(http.Client.new));

  List<http.BaseRequest> captureRequests() {
    final captured = <http.BaseRequest>[];
    api.debugSetHttpClientFactory(
      () => MockClient((request) async {
        captured.add(request);
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    return captured;
  }

  test(
    'fires with empty text when an icon/type filter is active, forwarding it',
    () async {
      final captured = captureRequests();

      final result =
          await Thread.searchRemote('', archived: false, iconFilter: ['plot']);

      expect(result, isEmpty);
      // The request was actually made — the old code early-returned on empty
      // text, which is the reported bug (filter-only browse never hit the
      // server, so unsynced Plot threads were missing).
      expect(captured, hasLength(1));
      final params = captured.single.url.queryParameters;
      expect(
        params.containsKey('q'),
        isFalse,
        reason: 'a filter-only browse must not send a text query',
      );
      expect(params['icon_filter'], jsonEncode(['plot']));
      expect(params['archived'], 'false');
    },
  );

  test('forwards tag / reaction / assignee / mute filters', () async {
    final captured = captureRequests();
    final assignee =
        ActorId.fromString('11111111-1111-1111-1111-111111111111');

    await Thread.searchRemote(
      '',
      archived: false,
      tagFilter: [Tag.yes],
      reactionFilter: ['🔥'],
      assigneeFilter: [assignee],
      muteOnly: true,
    );

    final params = captured.single.url.queryParameters;
    // Tag ids are integers shared 1:1 with the server's thread_tag.tag_id.
    expect(params['tag_filter'], jsonEncode([Tag.yes.id]));
    expect(params['reaction_filter'], jsonEncode(['🔥']));
    expect(params['assignee_filter'], jsonEncode([assignee.toString()]));
    expect(params['mute_only'], 'true');
  });

  test('forwards the text query alongside an active filter', () async {
    final captured = captureRequests();

    await Thread.searchRemote('hello', archived: false, iconFilter: ['plot']);

    final params = captured.single.url.queryParameters;
    expect(params['q'], 'hello');
    expect(params['icon_filter'], jsonEncode(['plot']));
  });

  test('still bails (no request) when there is neither text nor filter',
      () async {
    final captured = captureRequests();

    final result = await Thread.searchRemote('', archived: false);

    expect(result, isEmpty);
    expect(captured, isEmpty);
  });

  test('searchRemoteCount forwards filters and fires with empty text',
      () async {
    final captured = <http.BaseRequest>[];
    api.debugSetHttpClientFactory(
      () => MockClient((request) async {
        captured.add(request);
        return http.Response(
          '{"count": 3}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final count =
        await Thread.searchRemoteCount('', archived: true, iconFilter: ['plot']);

    expect(count, 3);
    expect(captured, hasLength(1));
    final params = captured.single.url.queryParameters;
    expect(params.containsKey('q'), isFalse);
    expect(params['icon_filter'], jsonEncode(['plot']));
    expect(params['count_only'], 'true');
    expect(params['archived'], 'true');
  });

  test('searchRemoteCount bails (no request) with neither text nor filter',
      () async {
    final captured = captureRequests();

    final count = await Thread.searchRemoteCount('', archived: true);

    expect(count, 0);
    expect(captured, isEmpty);
  });
}
