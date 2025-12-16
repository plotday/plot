import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A row widget with an icon and expandable content.
///
/// Used for scheduler-style inputs where a small icon precedes the input field.
/// The icon is 14px with muted foreground color, and the content expands to fill
/// the remaining space.
class IconInputRow extends StatelessWidget {
  const IconInputRow({
    required this.icon,
    required this.content,
    this.backgroundColor,
    super.key,
  });

  /// The icon to display on the left side (14px size).
  final IconData icon;

  /// The content widget that expands to fill the remaining space.
  final Widget content;

  /// Optional background color for the entire row.
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              icon,
              size: 14,
              color: context.theme.colors.mutedForeground,
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}
