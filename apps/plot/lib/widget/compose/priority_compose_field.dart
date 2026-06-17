import 'package:flutter/services.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Either an existing priority or the synthetic "Auto-organize" choice.
/// Drives the items in the priority picker modal — picking
/// [AutoOrganizeChoice] flips the draft into auto-organize mode.
sealed class PriorityChoice {
  String get label;
}

/// Synthetic choice that flips the draft into auto-organize mode.
class AutoOrganizeChoice implements PriorityChoice {
  const AutoOrganizeChoice();
  @override
  String get label => 'Auto-organize';
  @override
  bool operator ==(Object other) => other is AutoOrganizeChoice;
  @override
  int get hashCode => 0;
}

/// Wraps an existing [Priority] as a [PriorityChoice].
class PickedPriorityChoice implements PriorityChoice {
  const PickedPriorityChoice(this.priority);
  final Priority priority;
  @override
  String get label => priority.title;
  @override
  bool operator ==(Object other) =>
      other is PickedPriorityChoice && other.priority.id == priority.id;
  @override
  int get hashCode => priority.id.hashCode;
}

/// Compose-surface priority field. Modal-only: tapping the row (or pressing
/// Enter when focused) opens [openModal], which is responsible for letting
/// the user pick a priority or Auto-organize.
class PriorityComposeField extends StatelessWidget {
  const PriorityComposeField({
    super.key,
    required this.currentPriority,
    required this.isAuto,
    required this.openModal,
  });

  /// Currently selected priority (irrelevant when [isAuto] is true).
  final Priority currentPriority;

  /// True when the draft is in auto-organize mode.
  final bool isAuto;

  /// Opens the priority/auto picker. Called on tap, Enter, or Space.
  final Future<void> Function() openModal;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final fontSize = theme.typography.md.fontSize;
    final label = isAuto
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ComposeLeadingIcon(
                child: Icon(PlotIcon.sparkles, size: theme.iconSizes.leading),
              ),
              const SizedBox(width: composeIconGap),
              const Text('Auto-organize'),
            ],
          )
        : FocusLabel(
            priority: currentPriority,
            fontSize: fontSize,
            // Match the leading-icon geometry of every other compose row so
            // the focus icon centers in the same column and the label starts
            // at the same x (see ComposeLeadingIcon / composeIconGap), at the
            // cap-height leading size shared by those rows' glyphs.
            iconSize: theme.iconSizes.leading,
            iconColumnWidth: composeLeadingWidth(context),
            iconGap: composeIconGap,
          );

    return ComposeSelectField(
      tooltip: 'Focus',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyP,
        shift: true,
      ),
      label: label,
      onOpen: openModal,
    );
  }
}
