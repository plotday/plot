import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/style/layout.dart';
import 'package:plot/widget/thread_assignee.dart';

/// The thread-row assignee avatar derives its diameter from the ghost
/// icon-button's padding, but must never grow larger than the New Thread picker
/// avatars ([listRowGutter], 24). On mobile the button's icon padding is 14,
/// which previously pushed the diameter to 44px — larger than the row is tall,
/// so adjacent rows' avatars overlapped.
void main() {
  group('assigneeAvatarSize', () {
    const iconSize = 16.0;

    test('caps the mobile diameter at the list-row avatar size', () {
      // Mobile ghost-button icon padding is 14 → uncapped 16+14+14 = 44.
      const mobilePadding = EdgeInsets.all(14);
      expect(assigneeAvatarSize(iconSize, mobilePadding), listRowGutter);
      expect(assigneeAvatarSize(iconSize, mobilePadding), lessThanOrEqualTo(24));
    });

    test('caps the desktop diameter at the list-row avatar size', () {
      // Desktop ghost-button icon padding is 7.5 → uncapped 16+7.5+7.5 = 31.
      const desktopPadding = EdgeInsets.all(7.5);
      expect(assigneeAvatarSize(iconSize, desktopPadding), listRowGutter);
    });

    test('does not enlarge when the derived size is already below the cap', () {
      const tightPadding = EdgeInsets.all(2);
      expect(assigneeAvatarSize(iconSize, tightPadding), iconSize + 4);
    });
  });
}
