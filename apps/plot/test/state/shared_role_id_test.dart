import 'package:flutter_test/flutter_test.dart';

import 'package:plot/state/move_recency.dart';
import 'package:plot/store/store.dart';

void main() {
  group('sharedRoleId', () {
    test('returns the role when every id is the same non-null role', () {
      final r = Uuid.generate();
      expect(sharedRoleId([r, r, r]), r);
    });

    test('returns the role for a single-element selection', () {
      final r = Uuid.generate();
      expect(sharedRoleId([r]), r);
    });

    test('returns null when the selection spans multiple roles', () {
      expect(sharedRoleId([Uuid.generate(), Uuid.generate()]), isNull);
    });

    test('returns null when a role id and null are mixed', () {
      expect(sharedRoleId([Uuid.generate(), null]), isNull);
    });

    test('returns null when every id is null', () {
      expect(sharedRoleId([null, null]), isNull);
    });

    test('returns null for an empty selection', () {
      expect(sharedRoleId(const <Uuid?>[]), isNull);
    });
  });
}
