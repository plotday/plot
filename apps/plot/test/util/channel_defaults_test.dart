import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/util/channel_defaults.dart';

/// Unit tests for [ChannelDefaultSuggester.selectEnabledChannels] — the
/// "enable everything reasonable, filter out the low-value" default-selection
/// logic, covering the tri-state connector hint and the title heuristics.
void main() {
  TwistChannel channel(
    String id,
    String title, {
    bool? enabledByDefault,
    String providerKey = 'p',
    List<TwistChannel> children = const [],
  }) =>
      TwistChannel(
        provider: AuthProvider.other,
        providerKey: providerKey,
        id: id,
        title: title,
        enabledByDefault: enabledByDefault,
        enabled: false,
        currentUserHasAccess: true,
        children: children,
      );

  Set<String> select(List<TwistChannel> channels) =>
      ChannelDefaultSuggester.selectEnabledChannels(channels);

  group('default = enable all top-level', () {
    test('plain top-level channels are all enabled', () {
      final result = select([
        channel('a', 'Engineering'),
        channel('b', 'Marketing'),
        channel('c', 'Sales'),
      ]);
      expect(result, {'p:a', 'p:b', 'p:c'});
    });

    test('empty channel list yields empty selection', () {
      expect(select(const []), isEmpty);
    });
  });

  group('connector hint (tri-state)', () {
    test('enabledByDefault:false excludes a channel', () {
      final result = select([
        channel('a', 'Work'),
        channel('b', 'Someone shared calendar', enabledByDefault: false),
      ]);
      expect(result, contains('p:a'));
      expect(result, isNot(contains('p:b')));
    });

    test('enabledByDefault:true forces a channel on despite a low-value title',
        () {
      // A user's calendar that happens to be titled "Birthdays" should still
      // be honored if the connector explicitly flags it.
      final result = select([
        channel('a', 'Birthdays', enabledByDefault: true),
      ]);
      expect(result, {'p:a'});
    });

    test('Google Calendar shape: owned on, shared/holiday off', () {
      // Mirrors what the connector now emits via accessRole === "owner".
      final result = select([
        channel('me@x.test', 'Me', enabledByDefault: true),
        channel('work', 'Side project', enabledByDefault: true),
        channel('team@group', 'Team shared', enabledByDefault: false),
        channel('holiday@group', 'Holidays in Canada', enabledByDefault: false),
      ]);
      expect(result, {'p:me@x.test', 'p:work'});
    });

    test('Gmail shape: Inbox + Sent on, other labels off', () {
      final result = select([
        channel('INBOX', 'Inbox', enabledByDefault: true),
        channel('SENT', 'Sent', enabledByDefault: true),
        channel('IMPORTANT', 'Important', enabledByDefault: false),
        channel('Label_1', 'Receipts', enabledByDefault: false),
      ]);
      expect(result, {'p:INBOX', 'p:SENT'});
    });
  });

  group('low-value title heuristics (hint == null)', () {
    test('holiday and birthday calendars are excluded', () {
      final result = select([
        channel('a', 'Work'),
        channel('b', 'Holidays in Canada'),
        channel('c', 'Birthdays'),
      ]);
      expect(result, {'p:a'});
    });

    test('low-value email labels are excluded', () {
      final result = select([
        channel('a', 'Inbox'),
        channel('b', 'SENT'),
        channel('c', 'DRAFT'),
        channel('d', 'CATEGORY_PROMOTIONS'),
      ]);
      expect(result, {'p:a'});
    });
  });

  group('trees', () {
    test('null children are NOT auto-enabled (only top-level)', () {
      // GitHub-shaped: owner parent off, repo children left for the user.
      final result = select([
        channel('owner', 'octocat', enabledByDefault: false, children: [
          channel('octocat/repo1', 'octocat/repo1'),
          channel('octocat/repo2', 'octocat/repo2'),
        ]),
      ]);
      expect(result, isEmpty);
    });

    test('Drive-shaped: all three roots on, sub-folders stay collapsed', () {
      final result = select([
        channel('my-drive', 'My Drive', children: [
          channel('folderA', 'Folder A'),
        ]),
        channel('shared-drives', 'Shared drives',
            children: [channel('sd1', 'Team Drive')]),
        channel('shared-with-me', 'Shared with me'),
      ]);
      // All three top-level roots are enabled; their folder children are not
      // auto-enabled (the user can drill in to narrow scope).
      expect(result, {'p:my-drive', 'p:shared-drives', 'p:shared-with-me'});
    });

    test('an explicit-true child is honored even under an excluded parent', () {
      final result = select([
        channel('parent', 'Container', enabledByDefault: false, children: [
          channel('child', 'Important', enabledByDefault: true),
        ]),
      ]);
      expect(result, {'p:child'});
    });
  });
}
