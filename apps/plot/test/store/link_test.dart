import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('LinkTypeConfig.fromJson', () {
    test('parses the four new compose/reply copy fields', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'note_label': 'Reply',
        'compose_placeholder': 'Send a Gmail email',
        'compose_verb': 'Send',
        'reply_placeholder': 'Reply',
        'reply_verb': 'Send',
      });
      expect(cfg.composePlaceholder, 'Send a Gmail email');
      expect(cfg.composeVerb, 'Send');
      expect(cfg.replyPlaceholder, 'Reply');
      expect(cfg.replyVerb, 'Send');
    });

    test('the four new fields default to null when absent', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'note',
        'label': 'Note',
      });
      expect(cfg.composePlaceholder, isNull);
      expect(cfg.composeVerb, isNull);
      expect(cfg.replyPlaceholder, isNull);
      expect(cfg.replyVerb, isNull);
    });

    test('parses camelCase variants of the four new fields', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'composePlaceholder': 'New email',
        'composeVerb': 'Send',
        'replyPlaceholder': 'Reply here',
        'replyVerb': 'Send reply',
      });
      expect(cfg.composePlaceholder, 'New email');
      expect(cfg.composeVerb, 'Send');
      expect(cfg.replyPlaceholder, 'Reply here');
      expect(cfg.replyVerb, 'Send reply');
    });
  });
}
