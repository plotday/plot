import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos_ui;
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/util/theme_color.dart';
import 'tapable.dart';

class ListTile extends StatelessWidget {
  const ListTile({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.leadingSize,
    this.onTap,
    this.selected = false,
    ThemeColor? color,
    super.key,
  }) : color = color ?? const ThemeColor.defaultColor();

  final VoidCallback? onTap;
  final bool selected;
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Size? leadingSize;
  final ThemeColor color;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Tapable(
        onTap: onTap,
        child: Container(
          color: selected
              ? const ThemeColor.defaultColor().getBackground(context)
              : material.Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            child: macos_ui.MacosListTile(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  title,
                  if (trailing != null) trailing!,
                ],
              ),
              subtitle: subtitle,
              leading: leadingSize != null
                  ? SizedBox.fromSize(
                      size: leadingSize!, child: Center(child: leading))
                  : leading,
            ),
          ),
        ),
      ),
      builder: (_) => material.ListTile(
        onTap: onTap,
        title: title,
        subtitle: subtitle,
        leading: leading,
        selected: selected,
        tileColor: selected ? color.getBackground(context) : null,
      ),
    );
  }
}

class ListHeader extends StatelessWidget {
  const ListHeader({
    required this.title,
    this.action,
    super.key,
  });

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        title.toUpperCase(),
        overflow: TextOverflow.ellipsis,
        style: context.theme.typography.xs.copyWith(
          color: context.theme.colorScheme.mutedForeground,
        ),
      ),
      trailing: action,
    );
  }
}
