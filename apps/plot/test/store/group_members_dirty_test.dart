import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Proves [GroupsBase.toBase] only serializes `member_contact_ids` when the
/// row carries the local-only `membersDirty` intent flag.
///
/// This guards a multi-device data-loss bug: the server's `save_group` runs a
/// full-set membership diff whenever `member_contact_ids` is present, so a
/// plain rename that rode along a STALE cached roster would silently remove
/// members another device added. Omitting the key (rename case) makes the
/// server skip the diff.
void main() {
  GroupRow buildGroup({
    required bool? membersDirty,
    List<Uuid> members = const [],
  }) {
    return GroupRow(
      updatedAt: DateTime.now().toUtc(),
      id: Uuid.generate(),
      name: 'Engineering',
      type: 'private',
      joinPolicy: 'member',
      autoMaintained: false,
      isAdmin: true,
      isMember: true,
      canPost: true,
      privacy: 'open',
      canAddress: true,
      memberContactIds: members,
      membersDirty: membersDirty,
    );
  }

  test('toBase OMITS member_contact_ids when not membersDirty (rename)', () {
    final row = buildGroup(
      membersDirty: null,
      members: [Uuid.generate(), Uuid.generate()],
    );
    final payload = GroupsBase().toBase(row);

    expect(
      payload.containsKey('member_contact_ids'),
      isFalse,
      reason: 'a non-dirty row must not send the membership set',
    );
    // Identity fields are always present.
    expect(payload['id'], row.id.toString());
    expect(payload['name'], 'Engineering');
    expect(payload['privacy'], 'open');
  });

  test('toBase also OMITS member_contact_ids when membersDirty is false', () {
    final row = buildGroup(membersDirty: false, members: [Uuid.generate()]);
    final payload = GroupsBase().toBase(row);
    expect(payload.containsKey('member_contact_ids'), isFalse);
  });

  test('toBase INCLUDES member_contact_ids when membersDirty (membership op)',
      () {
    final a = Uuid.generate();
    final b = Uuid.generate();
    final row = buildGroup(membersDirty: true, members: [a, b]);
    final payload = GroupsBase().toBase(row);

    expect(payload.containsKey('member_contact_ids'), isTrue);
    expect(
      payload['member_contact_ids'],
      [a.toString(), b.toString()],
    );
    expect(payload['id'], row.id.toString());
    expect(payload['name'], 'Engineering');
    expect(payload['privacy'], 'open');
  });

  test('toBase sends an empty list when dirty with no members', () {
    final row = buildGroup(membersDirty: true, members: const []);
    final payload = GroupsBase().toBase(row);
    expect(payload.containsKey('member_contact_ids'), isTrue);
    expect(payload['member_contact_ids'], <String>[]);
  });
}
