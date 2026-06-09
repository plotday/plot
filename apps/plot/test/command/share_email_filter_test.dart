import 'package:flutter_test/flutter_test.dart';

import 'package:plot/command/share.dart';
import 'package:plot/store/store.dart';

Actor _actor({String? email}) => Actor.fromStore(
      ActorRow(
        updatedAt: DateTime.now(),
        createdAt: DateTime.now(),
        id: ActorId.fromUuid(Uuid.generate()),
        type: ActorType.contact,
        name: 'Test Contact',
        email: email,
        self: false,
        inviteable: true,
        primary: true,
        externalAccounts: const [],
      ),
    );

void main() {
  group('actorHasEmail', () {
    test('true when the actor has a non-empty email', () {
      expect(actorHasEmail(_actor(email: 'a@example.test')), isTrue);
    });
    test('false when the actor has no email', () {
      expect(actorHasEmail(_actor(email: null)), isFalse);
    });
    test('false when the actor email is blank', () {
      expect(actorHasEmail(_actor(email: '   ')), isFalse);
    });
  });
}
