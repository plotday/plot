import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/util/uuid.dart';

void main() {
  DraftInput input(
    String hex, {
    String? title,
    bool hasRecipients = false,
    bool hasSchedule = false,
    String? body,
    bool hasActions = false,
    String? recipientSummary,
    String? logo,
    required int sortMs,
    bool archived = false,
  }) =>
      DraftInput(
        threadId: Uuid.fromString('00000000-0000-0000-0000-0000000000$hex'),
        title: title,
        hasRecipients: hasRecipients,
        hasSchedule: hasSchedule,
        body: body,
        hasActions: hasActions,
        recipientSummary: recipientSummary,
        logo: logo,
        logoDark: null,
        focus: null,
        sortKey: DateTime.fromMillisecondsSinceEpoch(sortMs),
        archived: archived,
      );

  test('drops skeleton drafts (no content)', () {
    final out = buildDraftSummaries(
      [input('01', sortMs: 1), input('02', title: 'Real', sortMs: 2)],
      const [],
    );
    expect(out.map((d) => d.label), ['Real']);
  });

  test('orders active drafts most-recent first', () {
    final out = buildDraftSummaries(
      [
        input('01', title: 'Old', sortMs: 1),
        input('02', title: 'New', sortMs: 9),
        input('03', title: 'Mid', sortMs: 5),
      ],
      const [],
    );
    expect(out.map((d) => d.label), ['New', 'Mid', 'Old']);
  });

  test('label falls back recipients → Untitled', () {
    final out = buildDraftSummaries(
      [
        input('01', hasRecipients: true, recipientSummary: 'To: Bob', sortMs: 2),
        input('02', hasSchedule: true, sortMs: 1),
      ],
      const [],
    );
    expect(out.map((d) => d.label), ['To: Bob', 'Untitled draft']);
  });

  test('archived drafts appended after active, capped at limit, recency order',
      () {
    final archived = [
      for (var i = 0; i < 8; i++)
        input('1$i', title: 'A$i', sortMs: i, archived: true),
    ];
    final out = buildDraftSummaries(
      [input('01', title: 'Active', sortMs: 100)],
      archived,
      archivedLimit: 5,
    );
    expect(out.first.label, 'Active');
    expect(out.first.archived, isFalse);
    final archivedOut = out.where((d) => d.archived).toList();
    expect(archivedOut.length, 5);
    // Most-recently-archived (highest sortMs) first.
    expect(archivedOut.map((d) => d.label), ['A7', 'A6', 'A5', 'A4', 'A3']);
  });

  test('skeleton archived drafts are excluded before the cap', () {
    final archived = [
      input('11', sortMs: 5, archived: true), // skeleton, dropped
      input('12', title: 'Keep', sortMs: 4, archived: true),
    ];
    final out = buildDraftSummaries(const [], archived, archivedLimit: 5);
    expect(out.map((d) => d.label), ['Keep']);
  });
}
