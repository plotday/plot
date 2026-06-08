import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/group.dart';
import 'package:plot/util/uuid.dart';

void main() {
  Uuid u(int n) => Uuid.fromString('00000000-0000-0000-0000-${n.toString().padLeft(12, '0')}');

  test('groupMembershipDiff computes added and removed', () {
    final prev = [u(1), u(2), u(3)];
    final next = [u(2), u(3), u(4)];
    final diff = groupMembershipDiff(prev, next);
    expect(diff.added.map((x) => x.toString()), [u(4).toString()]);
    expect(diff.removed.map((x) => x.toString()), [u(1).toString()]);
  });

  test('groupMembershipDiff is empty when unchanged', () {
    final same = [u(1), u(2)];
    final diff = groupMembershipDiff(same, [u(2), u(1)]);
    expect(diff.added, isEmpty);
    expect(diff.removed, isEmpty);
  });

  test('groupMembershipDiff handles empty next (remove all)', () {
    final diff = groupMembershipDiff([u(1), u(2)], const []);
    expect(diff.added, isEmpty);
    expect(diff.removed.length, 2);
  });
}
