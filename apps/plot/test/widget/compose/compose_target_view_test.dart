import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/compose_target_view.dart';

void main() {
  group('resolveRecipientDisplays', () {
    test('single address for a name -> bare, no email shown', () {
      final out = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@plot.day', actorId: null)],
        nameToEmailsForConnection: const {'kris braun': ['kris@plot.day']},
      );
      expect(out.single.showEmail, isFalse);
    });

    test('primary address bare, secondary shows email', () {
      final byName = {'kris braun': ['kris@plot.day', 'kris@personal.com']};
      final primary = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@plot.day', actorId: null)],
        nameToEmailsForConnection: byName,
      );
      final secondary = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@personal.com', actorId: null)],
        nameToEmailsForConnection: byName,
      );
      expect(primary.single.showEmail, isFalse);
      expect(secondary.single.showEmail, isTrue);
    });

    test('name match is case-insensitive', () {
      final out = resolveRecipientDisplays(
        recipients: const [(name: 'KRIS BRAUN', email: 'kris@personal.com', actorId: null)],
        nameToEmailsForConnection: const {
          'kris braun': ['kris@plot.day', 'kris@personal.com']
        },
      );
      expect(out.single.showEmail, isTrue);
    });

    test('no email -> never shows email', () {
      final out = resolveRecipientDisplays(
        recipients: const [(name: 'Greg', email: null, actorId: null)],
        nameToEmailsForConnection: const {'greg': ['a@x.com', 'b@x.com']},
      );
      expect(out.single.showEmail, isFalse);
    });
  });
}
