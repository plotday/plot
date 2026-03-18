import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/badge.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/modal.dart';

/// Minimum touch target size per Apple/Android guidelines (48dp).
const _kMinTouchTarget = 48.0;

/// A horizontal row of tappable tag icon buttons for compact modal layouts.
///
/// Renders active tags (with selected styling and count badges) followed by
/// suggested tags (muted), truncated to fit available width with a "..."
/// button always at the end. Tapping any tag closes all modals.
class TagRow extends StatefulWidget {
  const TagRow({
    required this.activeTags,
    required this.suggestedTags,
    required this.activeTagCounts,
    required this.commandBuilder,
    required this.showAllBuilder,
    this.selectedColor,
    super.key,
  });

  /// Tags currently on the item.
  final List<Tag> activeTags;

  /// Suggested tags to add (muted style).
  final List<Tag> suggestedTags;

  /// Count per active tag (for [CountBadge]).
  final Map<Tag, int> activeTagCounts;

  /// Builds the toggle command for a given tag.
  final Command Function(Tag tag) commandBuilder;

  /// Builds the "show all tags" command for the "..." button.
  final Command Function() showAllBuilder;

  /// Accent color for active tag buttons.
  final Color? selectedColor;

  @override
  State<TagRow> createState() => _TagRowState();
}

class _TagRowState extends State<TagRow> {
  late Set<Tag> _optimisticActive;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _optimisticActive = Set.of(widget.activeTags);
  }

  @override
  void didUpdateWidget(TagRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _optimisticActive = Set.of(widget.activeTags);
  }

  Future<void> _onTagTap(Tag tag) async {
    if (_busy) return;
    _busy = true;

    final wasActive = _optimisticActive.contains(tag);
    setState(() {
      if (wasActive) {
        _optimisticActive.remove(tag);
      } else {
        _optimisticActive.add(tag);
      }
    });

    try {
      final command = widget.commandBuilder(tag);
      await command.run(context);
    } catch (_) {
      // Revert optimistic state on error
      if (mounted) {
        setState(() {
          if (wasActive) {
            _optimisticActive.add(tag);
          } else {
            _optimisticActive.remove(tag);
          }
        });
      }
    }

    // Close all modals after toggling
    if (mounted) {
      await Modal.popAll(context);
    }
    _busy = false;
  }

  Future<void> _onMoreTap() async {
    if (_busy) return;
    _busy = true;

    try {
      final command = widget.showAllBuilder();
      await command.run(context);
    } catch (_) {
      // Ignore errors
    }

    // Close remaining modals after sub-modal returns
    if (mounted) {
      await Modal.popAll(context);
    }
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    // Build active tag buttons
    final activeButtons = <Widget>[];
    for (final tag in widget.activeTags) {
      if (!_optimisticActive.contains(tag)) continue;
      activeButtons.add(_TagButton(
        icon: tag.icon,
        color: widget.selectedColor ?? context.theme.colors.primary,
        count: widget.activeTagCounts[tag] ?? 0,
        onTap: () => _onTagTap(tag),
      ));
    }

    // Build suggested tag buttons
    final suggestedButtons = <Widget>[];
    for (final tag in widget.suggestedTags) {
      if (_optimisticActive.contains(tag)) continue;
      suggestedButtons.add(_TagButton(
        icon: tag.icon,
        color: context.theme.colors.mutedForeground,
        onTap: () => _onTagTap(tag),
      ));
    }

    // "..." button always at the end
    final moreButton = _TagButton(
      icon: PlotIcon.more,
      color: context.theme.colors.mutedForeground,
      onTap: _onMoreTap,
    );

    final allButtons = [...activeButtons, ...suggestedButtons, moreButton];

    final spacing = context.theme.spacing;

    return Padding(
          padding: spacing.paddingSm.copyWith(
            top: 0,
            bottom: 0,
          ),
          child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.maxWidth.isFinite) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: allButtons,
            );
          }

          final maxButtons =
              (constraints.maxWidth / _kMinTouchTarget).floor();

          List<Widget> visibleButtons;
          if (allButtons.length <= maxButtons) {
            visibleButtons = allButtons;
          } else if (maxButtons <= 1) {
            visibleButtons = [moreButton];
          } else {
            visibleButtons = [
              ...allButtons.sublist(0, maxButtons - 1),
              moreButton,
            ];
          }

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: visibleButtons,
          );
        },
      ),
    );
  }
}

/// A single tag button with 48dp touch target and ghost-style hover/press.
class _TagButton extends StatefulWidget {
  const _TagButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.count = 0,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final int count;

  @override
  State<_TagButton> createState() => _TagButtonState();
}

class _TagButtonState extends State<_TagButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final iconSize = theme.iconSizes.base;
    final iconColor = _hovered || _pressed
        ? theme.colors.foreground
        : widget.color;

    Widget icon = Icon(widget.icon, size: iconSize, color: iconColor);

    if (widget.count > 1) {
      icon = CountBadge(count: widget.count, child: icon);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          width: _kMinTouchTarget,
          height: _kMinTouchTarget,
          decoration: BoxDecoration(
            color: _pressed ? theme.colors.secondary : null,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }
}
