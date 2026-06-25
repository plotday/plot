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

    test('parses sourceName (snake_case and camelCase)', () {
      expect(
        LinkTypeConfig.fromJson({
          'type': 'event',
          'label': 'Event',
          'source_name': 'Google Calendar',
        }).sourceName,
        'Google Calendar',
      );
      expect(
        LinkTypeConfig.fromJson({
          'type': 'email',
          'label': 'Thread',
          'sourceName': 'Gmail',
        }).sourceName,
        'Gmail',
      );
    });

    test('sourceName defaults to null when absent', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'note', 'label': 'Note'});
      expect(cfg.sourceName, isNull);
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

    test('parses supportsLinks / supportsFileAttachments (camelCase)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'supportsLinks': true,
        'supportsFileAttachments': true,
      });
      expect(cfg.supportsLinks, isTrue);
      expect(cfg.supportsFileAttachments, isTrue);
    });

    test('parses supportsLinks / supportsFileAttachments (snake_case)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'supports_links': true,
        'supports_file_attachments': true,
      });
      expect(cfg.supportsLinks, isTrue);
      expect(cfg.supportsFileAttachments, isTrue);
    });

    test('supportsLinks / supportsFileAttachments default to false', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'note',
        'label': 'Note',
      });
      expect(cfg.supportsLinks, isFalse);
      expect(cfg.supportsFileAttachments, isFalse);
    });

    test('parses includesSchedules (camelCase)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'event',
        'label': 'Event',
        'includesSchedules': true,
      });
      expect(cfg.includesSchedules, isTrue);
    });

    test('parses includes_schedules (snake_case)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'event',
        'label': 'Event',
        'includes_schedules': true,
      });
      expect(cfg.includesSchedules, isTrue);
    });

    test('includesSchedules defaults to false when absent', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'note', 'label': 'Note'});
      expect(cfg.includesSchedules, isFalse);
    });
  });
}
