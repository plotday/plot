import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';
import 'package:plot/widget_bridge/widget_bridge_channel.dart';
import 'package:plot/widget_bridge/widget_navigation.dart';

class _FakeNav implements WidgetNavigator {
  final calls = <String>[];
  @override
  Future<void> openFocus(String priorityId) async =>
      calls.add('focus:$priorityId');
  @override
  Future<void> openThread(String threadId, String priorityId) async =>
      calls.add('thread:$threadId@$priorityId');
  @override
  Future<void> showWindow() async => calls.add('show');
}

void main() {
  test('navigateThread routes through the navigator', () async {
    final nav = _FakeNav();
    final routed = await routeWidgetActionForTest(
      navigator: nav,
      name: widgetActionNavigateThread,
      args: {'threadId': 't1', 'priorityId': 'p1'},
    );
    expect(routed, isTrue);
    expect(nav.calls, contains('thread:t1@p1'));
  });

  test('openApp shows the window', () async {
    final nav = _FakeNav();
    await routeWidgetActionForTest(
      navigator: nav, name: widgetActionOpenApp, args: const {});
    expect(nav.calls, contains('show'));
  });

  test('navigateFocus routes through the navigator', () async {
    final nav = _FakeNav();
    final routed = await routeWidgetActionForTest(
      navigator: nav,
      name: widgetActionNavigateFocus,
      args: {'priorityId': 'p1'},
    );
    expect(routed, isTrue);
    expect(nav.calls, contains('focus:p1'));
  });
}
