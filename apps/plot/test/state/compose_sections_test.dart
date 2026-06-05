import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/util/uuid.dart';

void main() {
  ComposeTarget chat(List<String> contactHex, {List<String> groups = const []}) =>
      ComposeTarget.chat(
        teamId: null,
        hasTeams: false,
        contacts: contactHex.map(Uuid.fromString).toList(),
        groups: groups.map(Uuid.fromString).toList(),
      );

  test('dedupes by roster ignoring scope, preserves first-seen order', () {
    const a = '00000000-0000-0000-0000-000000000001';
    const b = '00000000-0000-0000-0000-000000000002';
    final targets = [chat([a]), chat([a]), chat([a, b]), chat([b])];
    final rosters = dedupePeopleByRoster(targets);
    expect(rosters.length, 3);
    expect(rosters[0].contacts.map((u) => u.toString()).toList(), [a]);
    expect((rosters[1].contacts.map((u) => u.toString()).toList()..sort()),
        ([a, b]..sort()));
    expect(rosters[2].contacts.map((u) => u.toString()).toList(), [b]);
  });

  test('empty rosters are skipped', () {
    expect(dedupePeopleByRoster([ComposeTarget.note(hasTeams: false)]), isEmpty);
  });
}
