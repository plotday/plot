import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

// --- Chip value ---

/// One value currently shown in the contacts field. The widget itself
/// renders a summary (avatars + text); editing happens entirely in the
/// share modal.
sealed class ContactChipValue {
  String get key;
  String get label;
}

/// A chip backed by a known [Actor] (contact or twist).
class ContactChipActor implements ContactChipValue {
  ContactChipActor(this.actor);
  final Actor actor;
  @override
  String get key => 'actor:${actor.id.toUuid()}';
  @override
  String get label => actor.name ?? actor.email ?? 'Unknown';
}

/// A chip backed by a known [GroupRow].
class ContactChipGroup implements ContactChipValue {
  ContactChipGroup(this.group);
  final GroupRow group;
  @override
  String get key => 'group:${group.id}';
  @override
  String get label => group.name;
}

/// A chip backed by a raw email address (invite, not yet a known contact).
class ContactChipEmail implements ContactChipValue {
  ContactChipEmail(this.email);
  final String email;
  @override
  String get key => 'email:$email';
  @override
  String get label => email;
}

// --- Widget ---

/// Compose-surface contacts field. Modal-only: tapping the row (or pressing
/// Enter when focused) opens the share modal. When no contacts are
/// selected, the row shows a strike-through users icon and "Private".
/// Otherwise it shows an avatar group followed by a text summary.
class ContactsComposeField extends StatelessWidget {
  const ContactsComposeField({
    super.key,
    required this.chips,
    required this.openModal,
  });

  /// Currently selected chips (actors, groups, and pending email invites).
  final List<ContactChipValue> chips;

  /// Opens the share modal that owns all editing.
  final Future<void> Function() openModal;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final Widget label;
    if (chips.isEmpty) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ComposeLeadingIcon(
            child: Icon(
              FontAwesomeIcons.usersSlash,
              size: theme.iconSizes.base,
            ),
          ),
          const SizedBox(width: composeIconGap),
          const Text('Private'),
        ],
      );
    } else {
      final actors =
          chips.whereType<ContactChipActor>().map((c) => c.actor).toList();
      label = Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (actors.isNotEmpty) ...[
            ComposeLeadingIcon(
              child: AvatarGroup(
                actors: actors,
                totalCount: chips.length,
                maxVisible: 3,
                size: theme.iconSizes.base,
              ),
            ),
            const SizedBox(width: composeIconGap),
          ],
          Expanded(
            child: Text(
              _summarize(chips),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.md.copyWith(
                color: theme.plotColors.muted,
              ),
            ),
          ),
        ],
      );
    }

    return ComposeSelectField(
      tooltip: 'Share with',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyS,
        shift: true,
      ),
      label: label,
      onOpen: openModal,
    );
  }
}

/// Builds the readable summary shown next to the avatar group:
/// "Alice", "Alice and Bob", "Alice, Bob, and Charlie", or
/// "Alice, Bob, and 3 others" once the list overflows.
String _summarize(List<ContactChipValue> chips) {
  if (chips.isEmpty) return 'Private';
  final labels = chips.map((c) => c.label).toList(growable: false);
  switch (labels.length) {
    case 1:
      return labels[0];
    case 2:
      return '${labels[0]} and ${labels[1]}';
    case 3:
      return '${labels[0]}, ${labels[1]}, and ${labels[2]}';
    default:
      final remaining = labels.length - 2;
      return '${labels[0]}, ${labels[1]}, and $remaining others';
  }
}
