import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/open_thread_link.dart';

void main() {
  group('OpenThreadLink', () {
    test('title names the connector', () {
      final cmd = OpenThreadLink(
        url: 'https://linear.app/x/issue/ABC-1',
        connectorName: 'Linear',
      );
      expect(cmd.title, 'Open in Linear');
    });

    test('falls back to a generic title when connector name is null', () {
      final cmd = OpenThreadLink(
        url: 'https://example.com/x',
        connectorName: null,
      );
      expect(cmd.title, 'Open in source');
    });
  });
}
