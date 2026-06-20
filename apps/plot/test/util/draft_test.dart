import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/draft.dart';

void main() {
  group('isSubstantiveDraftFields', () {
    bool sub({
      String? title,
      bool hasRecipients = false,
      bool hasSchedule = false,
      String? body,
      bool hasActions = false,
    }) => isSubstantiveDraftFields(
          title: title,
          hasRecipients: hasRecipients,
          hasSchedule: hasSchedule,
          body: body,
          hasActions: hasActions,
        );

    test('all empty → not substantive', () {
      expect(sub(), isFalse);
      expect(sub(title: '   ', body: ''), isFalse);
    });
    test('any single dimension → substantive', () {
      expect(sub(title: 'Hi'), isTrue);
      expect(sub(hasRecipients: true), isTrue);
      expect(sub(hasSchedule: true), isTrue);
      expect(sub(body: 'note text'), isTrue);
      expect(sub(hasActions: true), isTrue);
    });
    test('whitespace-only title/body do not count', () {
      expect(sub(title: '  ', body: '\n  \t'), isFalse);
    });
  });

  group('draftBodySnippet', () {
    test('null/empty → null', () {
      expect(draftBodySnippet(null), isNull);
      expect(draftBodySnippet('   '), isNull);
    });
    test('first non-empty line, trimmed', () {
      expect(draftBodySnippet('\n  first line\nsecond'), 'first line');
    });
    test('truncates to maxLen with ellipsis', () {
      final s = draftBodySnippet('a' * 200, maxLen: 10);
      expect(s, '${'a' * 10}…');
    });
  });

  group('draftPrimaryLabel', () {
    test('prefers title, then snippet, then recipients, then fallback', () {
      expect(
        draftPrimaryLabel(title: 'T', bodySnippet: 'B', recipientSummary: 'R'),
        'T',
      );
      expect(
        draftPrimaryLabel(title: '  ', bodySnippet: 'B', recipientSummary: 'R'),
        'B',
      );
      expect(
        draftPrimaryLabel(title: null, bodySnippet: null, recipientSummary: 'R'),
        'R',
      );
      expect(
        draftPrimaryLabel(title: null, bodySnippet: null, recipientSummary: null),
        'Untitled draft',
      );
    });
  });
}
