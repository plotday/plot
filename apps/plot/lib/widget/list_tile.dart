import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos_ui;
import 'package:platform_builder/platform_builder.dart';

import 'theme_color.dart';

class ListTile extends StatelessWidget {
  ListTile({
    required this.title,
    this.subtitle,
    this.leading,
    this.leadingSize,
    this.onTap,
    this.selected = false,
    ThemeColor? color,
    super.key,
  }) : color = color ?? ThemeColor.defaultColor();

  final VoidCallback? onTap;
  final bool selected;
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Size? leadingSize;
  final ThemeColor color;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: macos_ui.MacosListTile(
          onClick: onTap,
          title: title,
          subtitle: subtitle,
          leading: leadingSize != null
              ? SizedBox.fromSize(
                  size: leadingSize!, child: Center(child: leading))
              : leading,
          // TODO selected: selected,
          // TODO tileColor
        ),
      ),
      builder: (_) => material.ListTile(
        onTap: onTap,
        title: title,
        subtitle: subtitle,
        leading: leading,
        selected: selected,
        tileColor: color.getBackground(context),
      ),
    );
  }
}
