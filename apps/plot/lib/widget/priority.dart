import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/theme_color.dart';

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({
    required this.priority,
    this.context,
    this.selected = false,
    this.selectedBorder = true,
    this.onHover,
    this.indentLevel = 0,
    this.textStyle,
    this.showAncestry = false,
    this.unread,
    this.active,
    this.reorderableIndex,
    this.onTap,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;

  /// Whether to show border when selected
  final bool selectedBorder;

  final void Function(bool hovered)? onHover;

  /// Indentation level for nested priorities
  final int indentLevel;

  /// Custom text style for the priority title
  final TextStyle? textStyle;

  /// Whether to show ancestry in the command (for top priorities)
  final bool showAncestry;

  /// Custom unread value (if null, uses priority.unread)
  final bool? unread;

  /// Custom active value (if null, uses priority.active)
  final bool? active;

  /// Index for reorderable list. If provided on mobile, shows trailing drag handle.
  final int? reorderableIndex;

  /// Optional tap callback that overrides the default navigation behavior.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext buildContext) {
    bool isContext = priority == context;
    final leadingH = buildContext.isMultiPanel
        ? buildContext.theme.spacing.lg
        : buildContext.theme.spacing.sm;
    final listTile = ListTile(
      command: !isContext
          ? ChangeCurrentPriority(priority, ancestry: showAncestry)
          : null,
      onTap: onTap,
      longPressCommand: !hasPhysicalKeyboard()
          ? ShowPriorityCommands(priority)
          : null,
      trailingBuilder: (isHovered, hasFocus) {
        final hovered = isHovered || hasFocus;
        final sharing = priority.sharing;
        final canShare = !priority.root;

        if (!hovered && !sharing) return null;

        return Padding(
          padding: EdgeInsets.only(right: leadingH),
          child: Row(
            children: [
              // Hover commands appear to the left
              if (hovered) ...[
                if (canShare && !sharing)
                  Button.icon(ManagePrioritySharing(priority)),
                Button.icon(
                  SetTopPriority(priority, priority.topOrder == null),
                ),
                Button.icon(ShowPriorityCommands(priority)),
              ],
              // Persistent sharing icon (rightmost)
              if (canShare && sharing)
                Button.icon(
                  ManagePrioritySharing(priority),
                  color: hovered
                      ? buildContext.theme.plotColors.muted
                      : buildContext.theme.plotColors.veryMuted,
                  hoverColor: buildContext.theme.colors.foreground,
                ),
            ],
          ),
        );
      },
      title: showAncestry ? null : priority.title,
      body: showAncestry
          ? PriorityLabel(
              priority: priority,
              fontSize: textStyle?.fontSize,
              height: textStyle?.height,
            )
          : null,
      selected: selected,
      selectedBorder: selectedBorder,
      highlighted: selected,
      onHover: onHover,
      indentLevel: indentLevel,
      textStyle: textStyle,
      leadingBuilder: (isHovered, hasFocus) => Padding(
        padding: EdgeInsets.only(
          left: leadingH,
          right: buildContext.theme.spacing.sm,
          bottom: 2,
        ),
        child: PriorityNotification(
          unread: unread ?? priority.unread,
          active: active ?? priority.active,
          color: priority.displayColor,
        ),
      ),
    );

    if (!hasPhysicalKeyboard() && reorderableIndex != null) {
      return Row(
        children: [
          Expanded(child: listTile),
          ReorderableDragStartListener(
            index: reorderableIndex!,
            child: Container(
              color: const Color(0x00000000),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Icon(
                FontAwesomeIcons.gripDotsVertical,
                size: buildContext.theme.iconSizes.sm,
                color: buildContext.theme.plotColors.muted,
              ),
            ),
          ),
        ],
      );
    }

    if (hasPhysicalKeyboard()) {
      return ContextMenu(
        items: (close) => priorityCommands(priority)
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
                onPress: () {
                  close();
                  buildContext.run(cmd);
                },
              ),
            )
            .toList(),
        child: listTile,
      );
    }

    return listTile;
  }
}

/// Standard widget for displaying a priority with its colored hierarchy.
///
/// Use this in all priority selection UIs:
/// - In SelectModal: `itemBuilder: (p) => ListTile(body: PriorityLabel(priority: p))`
/// - In FormSelect: `labelBuilder: (p) => PriorityLabel(priority: p)`
/// - For display: `PriorityLabel(priority: priority, muted: true)` for subdued appearance
class PriorityLabel extends StatelessWidget {
  PriorityLabel({
    List<PriorityAncestor>? ancestors,
    this.priority,
    Priority? context,
    this.onSelect,
    this.fontSize,
    this.height,
    this.muted = false,
    this.color,
    super.key,
  }) : ancestors = (() {
         final computed =
             ancestors ?? priority?.ancestors(context: context) ?? const [];
         return computed;
       }());

  final List<PriorityAncestor> ancestors;
  final Priority? priority;
  final void Function(PriorityId)? onSelect;
  final double? fontSize;
  final double? height;
  final bool muted;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // Compute display colors for each ancestor (with inheritance)
    ThemeColor currentColor = const ThemeColor.defaultColor();
    final displayColors = <ThemeColor>[];
    for (final ancestor in ancestors) {
      currentColor = ThemeColor(ancestor.color);
      displayColors.add(currentColor);
    }

    // Update current color with priority's color if present
    if (priority?.displayColor != null) {
      currentColor = priority!.displayColor;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...ancestors.indexed.expand((entry) {
          final i = entry.$1;
          final ancestor = entry.$2;
          final isLast = i == ancestors.length - 1;
          final ancestorColor =
              color ??
              context.colour.colours.fromTheme(displayColors[i], muted: muted);
          return [
            Flexible(
              key: ValueKey('ancestor_${ancestor.id}'),
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: ancestorColor,
                  fontSize: fontSize ?? context.theme.typography.md.fontSize,
                  height: height,
                ),
                child: Tapable(
                  onTap: () async {
                    if (onSelect != null) {
                      onSelect?.call(ancestor.id);
                    } else {
                      final priority = await Priority.getOne(ancestor.id);
                      if (!context.mounted) return;
                      context.run(ChangeCurrentPriority(priority));
                    }
                  },
                  child: Text(
                    ancestor.title,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
            if (!isLast || priority != null)
              DefaultTextStyle(
                key: ValueKey('separator_${ancestor.id}'),
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: color ?? context.theme.colors.mutedForeground,
                  fontSize: fontSize ?? context.theme.typography.md.fontSize,
                  height: height ?? 1,
                ),
                child: Text(Priority.separator),
              ),
          ];
        }),
        if (priority != null)
          Flexible(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color:
                    color ??
                    context.colour.colours.fromTheme(
                      currentColor,
                      muted: muted,
                    ),
                fontSize: fontSize ?? context.theme.typography.md.fontSize,
                height: height,
              ),
              child: Text(
                priority!.title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
      ],
    );
  }
}
