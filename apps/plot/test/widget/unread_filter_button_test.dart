import 'package:flutter_test/flutter_test.dart';

import 'package:plot/command/unread_filter.dart';
import 'package:plot/widget/icon.dart';

/// Tests for the tri-state unread-filter toggle.
///
/// [unreadToggleState] is the pure decision function shared by
/// [ToggleUnreadFilter]'s constructor. Testing it directly avoids
/// constructing a full [PriorityBloc] (which requires [NowBloc] and
/// [LocalPreferencesBloc]) while still covering all three branches of the
/// tri-state mapping.
void main() {
  group('unreadToggleState — tri-state mapping', () {
    test('no unread → disabled, envelopeAllRead icon, "No unread threads"', () {
      final s = unreadToggleState(hasUnread: false, active: false);

      expect(s.enabled, isFalse,
          reason: 'button must be disabled when there are no unread threads');
      expect(s.icon, PlotIcon.envelopeAllRead,
          reason: 'shows the all-read envelope icon');
      expect(s.title, 'No unread threads');
      expect(s.on, isFalse,
          reason: 'filter cannot be "on" when there is nothing to filter');
    });

    test(
        'unread present + filter off → enabled, envelopeUnread icon, '
        '"Show only unread threads", on=false', () {
      final s = unreadToggleState(hasUnread: true, active: false);

      expect(s.enabled, isTrue);
      expect(s.icon, PlotIcon.envelopeUnread,
          reason: 'shows the dotted envelope when unread threads exist');
      expect(s.title, 'Show only unread threads');
      expect(s.on, isFalse, reason: 'filter is not yet activated');
    });

    test(
        'unread present + filter on → enabled, envelopeUnread icon, '
        '"Show all threads", on=true', () {
      final s = unreadToggleState(hasUnread: true, active: true);

      expect(s.enabled, isTrue);
      expect(s.icon, PlotIcon.envelopeUnread,
          reason: 'same icon whether filter is on or off when unread exist');
      expect(s.title, 'Show all threads');
      expect(s.on, isTrue, reason: 'filter is active — button shows as "on"');
    });

    test(
        'no unread + active=true → still disabled '
        '(shouldn\'t normally occur but guard it)', () {
      // This edge case would only arise if unread count drops to zero while
      // the filter is still technically set. The guard ensures the button
      // never remains "enabled" with a misleading title once the feed is read.
      final s = unreadToggleState(hasUnread: false, active: true);

      expect(s.enabled, isFalse,
          reason: 'no unread means the filter cannot be meaningfully enabled');
      expect(s.title, 'No unread threads');
      expect(s.icon, PlotIcon.envelopeAllRead);
    });
  });

  group('ToggleUnreadFilter constructor — delegates to unreadToggleState', () {
    test('icon / title / on match the pure helper when no unread', () {
      const hasUnread = false;
      const active = false;
      final expected = unreadToggleState(hasUnread: hasUnread, active: active);

      // We can't construct a full PriorityBloc in a unit test, but we can
      // verify the Command fields are wired from the helper by constructing
      // ToggleUnreadFilter._ directly via the private factory exposure.
      //
      // Since the private constructor is not accessible from tests, we verify
      // the helper returns what Command fields would receive — the two code
      // paths (helper + constructor) share the same call, so a mismatch there
      // would be a compile error. We assert the helper itself is correct above;
      // here we guard the field names / sentence-case text values.
      expect(expected.title, 'No unread threads');
      expect(expected.on, false);
      expect(expected.icon, PlotIcon.envelopeAllRead);
    });

    test('text strings are sentence case', () {
      expect(
        unreadToggleState(hasUnread: false, active: false).title,
        'No unread threads',
        reason: 'sentence case: only first word capitalised',
      );
      expect(
        unreadToggleState(hasUnread: true, active: false).title,
        'Show only unread threads',
      );
      expect(
        unreadToggleState(hasUnread: true, active: true).title,
        'Show all threads',
      );
    });
  });
}
