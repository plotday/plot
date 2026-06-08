import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('LinkStatus.fromJson icon + hiddenDefault', () {
    test('parses every StatusIcon value (camelCase keys)', () {
      for (final entry in {
        'backlog': StatusIcon.backlog,
        'todo': StatusIcon.todo,
        'inProgress': StatusIcon.inProgress,
        'blocked': StatusIcon.blocked,
        'done': StatusIcon.done,
        'cancelled': StatusIcon.cancelled,
        'confirmed': StatusIcon.confirmed,
        'tentative': StatusIcon.tentative,
      }.entries) {
        final s = LinkStatus.fromJson({
          'status': 'x',
          'label': 'X',
          'icon': entry.key,
        });
        expect(s.icon, entry.value, reason: entry.key);
      }
    });

    test('parses hiddenDefault (camelCase and snake_case)', () {
      expect(
        LinkStatus.fromJson({
          'status': 'confirmed',
          'label': 'Confirmed',
          'icon': 'confirmed',
          'hiddenDefault': true,
        }).hiddenDefault,
        isTrue,
      );
      expect(
        LinkStatus.fromJson({
          'status': 'confirmed',
          'label': 'Confirmed',
          'icon': 'confirmed',
          'hidden_default': true,
        }).hiddenDefault,
        isTrue,
      );
    });

    test('icon is null and hiddenDefault false when absent', () {
      final s = LinkStatus.fromJson({'status': 'open', 'label': 'Open'});
      expect(s.icon, isNull);
      expect(s.hiddenDefault, isFalse);
    });

    test('unknown icon string parses to null (forward-compat)', () {
      final s = LinkStatus.fromJson({
        'status': 'open',
        'label': 'Open',
        'icon': 'someFutureIcon',
      });
      expect(s.icon, isNull);
    });
  });
}
