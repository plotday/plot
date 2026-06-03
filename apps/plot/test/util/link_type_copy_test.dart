import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/link_type_copy.dart';

void main() {
  group('composerHintForNewThreadPlot', () {
    test('returns "Add a note" when not shared', () {
      expect(composerHintForNewThreadPlot(shared: false), 'Add a note');
    });
    test('returns "Start a chat" when shared', () {
      expect(composerHintForNewThreadPlot(shared: true), 'Start a chat');
    });
  });

  group('composerHintForNewThread', () {
    test('prefers cfg.composePlaceholder when set', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'compose_placeholder': 'Send a Gmail email',
      });
      expect(composerHintForNewThread(cfg, connectorName: 'Gmail'), 'Send a Gmail email');
    });
    test('derives from label and connector name when unset', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'issue', 'label': 'Issue'});
      expect(composerHintForNewThread(cfg, connectorName: 'Linear'), 'Create a new Linear issue');
    });
    test('returns "Start a thread" when cfg is null', () {
      expect(composerHintForNewThread(null), 'Start a thread');
    });
    test('derives from label alone when no connector name', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'issue', 'label': 'Issue'});
      expect(composerHintForNewThread(cfg), 'Create a new issue');
    });
  });

  group('composerHintForNote', () {
    test('prefers cfg.replyPlaceholder when set', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue',
        'label': 'Issue',
        'reply_placeholder': 'Add a comment',
      });
      expect(composerHintForNote(cfg), 'Add a comment');
    });
    test('derives from noteLabel when reply_placeholder unset', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue',
        'label': 'Issue',
        'note_label': 'Comment',
      });
      expect(composerHintForNote(cfg), 'Add a comment');
    });
    test('returns "Add a note" when cfg is null', () {
      expect(composerHintForNote(null), 'Add a note');
    });
    test('returns "Add a note" when cfg has no noteLabel or replyPlaceholder', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'note', 'label': 'Note'});
      expect(composerHintForNote(cfg), 'Add a note');
    });
  });

  group('verb helpers', () {
    test('composerVerbForNewThread prefers composeVerb, defaults to "Create"', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'compose_verb': 'Send',
      });
      expect(composerVerbForNewThread(cfg), 'Send');
      expect(composerVerbForNewThread(null), 'Create');
    });
    test('composerVerbForNote prefers replyVerb, defaults to "Send"', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue',
        'label': 'Issue',
        'reply_verb': 'Comment',
      });
      expect(composerVerbForNote(cfg), 'Comment');
      expect(composerVerbForNote(null), 'Send');
    });
  });
}
