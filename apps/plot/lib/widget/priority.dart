import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/theme_color.dart';

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({
    required this.priority,
    this.context,
    this.selected = false,
    this.onHover,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;

  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    bool isContext = priority == this.context;
    // bool contextChild = priority.parentId == this.context?.id;
    return ListTile(
      command: !isContext
          ? CommandWrapper(ChangeCurrentPriority(priority), icon: Value(null))
          : null,
      trailingCommands: [ShowPriorityCommands(priority)],
      body: PriorityLabel(priority: priority),
      highlighted: selected,
      onHover: onHover,
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
    super.key,
  }) : ancestors =
           ancestors ?? priority?.ancestors(context: context) ?? const [];

  final List<PriorityAncestor> ancestors;
  final Priority? priority;
  final void Function(PriorityId)? onSelect;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    // Compute display colors for each ancestor (with inheritance)
    ThemeColor currentColor = const ThemeColor.defaultColor();
    final displayColors = <ThemeColor>[];
    for (final ancestor in ancestors) {
      if (ancestor.color != null) {
        currentColor = ThemeColor(ancestor.color!);
      }
      displayColors.add(currentColor);
    }

    // Update current color with priority's color if present
    if (priority?.color != null) {
      currentColor = priority!.color!;
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
          );
          return [
            Flexible(
              key: ValueKey('ancestor_${ancestor.id}'),
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: ancestorColor,
                  fontSize: fontSize ?? context.theme.typography.base.fontSize,
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
                ),
                child: Text(Priority.separator),
              ),
          ];
        }),
        if (priority != null)
          Flexible(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color: context.colour.colours.fromTheme(currentColor),
                fontSize: fontSize ?? context.theme.typography.base.fontSize,
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
