import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/channel_breadcrumb.dart';

void main() {
  group('formatChannelBreadcrumb', () {
    test('joins workspace and channel with a chevron when both present', () {
      expect(
        formatChannelBreadcrumb(workspace: 'Acme Co', channel: '#general'),
        'Acme Co › #general',
      );
    });

    test('returns the channel alone when workspace is missing', () {
      expect(
        formatChannelBreadcrumb(workspace: null, channel: '#general'),
        '#general',
      );
    });

    test('returns the workspace alone when channel is missing', () {
      expect(
        formatChannelBreadcrumb(workspace: 'Acme Co', channel: null),
        'Acme Co',
      );
    });

    test('returns null when neither part resolves', () {
      expect(formatChannelBreadcrumb(workspace: null, channel: null), isNull);
    });

    test('treats empty and whitespace-only parts as missing', () {
      expect(
        formatChannelBreadcrumb(workspace: '   ', channel: '#general'),
        '#general',
      );
      expect(
        formatChannelBreadcrumb(workspace: 'Acme Co', channel: ''),
        'Acme Co',
      );
      expect(formatChannelBreadcrumb(workspace: '', channel: '  '), isNull);
    });
  });
}
