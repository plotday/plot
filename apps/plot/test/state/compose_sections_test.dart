import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/widget/compose/compose_pill.dart';
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

  group('linkModeSections', () {
    // A focus-note target (always link-capable).
    ComposeTarget focus(String pid) => ComposeTarget.focusNote(
          priorityId: Uuid.fromString(pid),
          teamId: null,
          title: 'Focus $pid',
        );
    // A topic target (Plot-only channel; always link-capable).
    ComposeTarget topic(String tid, String name) => ComposeTarget.topic(
          topicId: Uuid.fromString(tid),
          name: name,
        );

    const p1 = '00000000-0000-0000-0000-0000000000a1';
    const p2 = '00000000-0000-0000-0000-0000000000a2';
    const t1 = '00000000-0000-0000-0000-0000000000b1';

    test('drops people & twists; orders focuses + topics by link MRU', () {
      final base = ComposeSections(
        people: [
          ComposePeopleEntry(
            contacts: [Uuid.fromString(p1)],
            groups: const [],
            inviteEmails: const [],
            display: const TopicPillData(''),
          ),
        ],
        twists: const [],
        channels: [topic(t1, 'Marketing')],
        focuses: [focus(p1), focus(p2)],
      );

      // Pretend focus p2 is the most-recently-used link destination.
      List<String> rank(List<String> sigs) {
        final f2 = focus(p2).signature;
        return [f2, ...sigs.where((s) => s != f2)];
      }

      final result = linkModeSections(base, rank, perSection: 8);

      expect(result.people, isEmpty);
      expect(result.twists, isEmpty);
      // Topic survives (Plot-only channels always support links).
      expect(result.channels.map((t) => t.label), ['Marketing']);
      // p2 floated to the front by the link-MRU ranking.
      expect(result.focuses.map((t) => t.priorityId.toString()), [p2, p1]);
    });
  });
}
