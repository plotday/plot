import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
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

  @override
  Widget build(BuildContext context) {
    bool isContext = priority == this.context;
    // bool contextChild = priority.parentId == this.context?.id;
    return ListTile(
      command: !isContext
          ? ChangeCurrentPriority(priority, ancestry: showAncestry)
          : null,
      trailingBuilder: (isHovered, hasFocus) => (isHovered || hasFocus)
          ? Row(
              children: [
                Button.icon(
                  SetTopPriority(priority, priority.topOrder == null),
                ),
                Button.icon(ShowPriorityCommands(priority)),
              ],
            )
          : null,
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
      leadingBuilder: (isHovered, hasFocus) => SizedBox(
        width: 20,
        child: UnreadIndicator(
          color: priority.displayColor,
          unread: unread ?? priority.unread,
        ),
      ),
    );
  }
}

class PriorityLabel extends StatelessWidget {
  PriorityLabel({
    List<PriorityAncestor>? ancestors,
    this.priority,
    Priority? context,
    this.onSelect,
    this.fontSize,
    this.height,
    this.muted = false,
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
          final ancestorColor = context.colour.colours.fromTheme(
            displayColors[i],
            muted: muted,
          );
          return [
            Flexible(
              key: ValueKey('ancestor_${ancestor.id}'),
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: ancestorColor,
                  fontSize: fontSize ?? context.theme.typography.base.fontSize,
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
                  color: context.theme.colors.mutedForeground,
                  fontSize: fontSize ?? context.theme.typography.base.fontSize,
                  height: height,
                ),
                child: Text(Priority.separator),
              ),
          ];
        }),
        if (priority != null)
          Flexible(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color: context.colour.colours.fromTheme(
                  currentColor,
                  muted: muted,
                ),
                fontSize: fontSize ?? context.theme.typography.base.fontSize,
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
