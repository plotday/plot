import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge_channel.dart';

void main() {
  test('new action names are stable and distinct', () {
    final names = {
      widgetActionNavigateThread,
      widgetActionNavigateFocus,
      widgetActionSetCurrentFocus,
      widgetActionJoinCall,
      widgetActionCapture,
      widgetActionOpenApp,
    };
    expect(names.length, 6);
    expect(widgetActionCapture, 'capture');
    expect(widgetActionJoinCall, 'joinCall');
  });
}
