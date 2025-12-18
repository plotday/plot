import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';

/// Shared layout component for form tiles (FormTextField, FormSelect, FormButton).
///
/// Provides a consistent single-column layout:
/// - Background layer: optional background color for the entire content area
/// - Content layer: label above content widget with small font
class FormTileLayout extends StatelessWidget {
  const FormTileLayout({
    required this.label,
    required this.content,
    this.rightBackgroundColor,
    this.isActive = false,
    super.key,
  });

  /// The label text displayed above the content in a small font.
  final String label;

  /// The content widget displayed below the label.
  final Widget content;

  /// Optional background color for the content area.
  final Color? rightBackgroundColor;

  /// Whether this form tile is active (focused, hovered, or highlighted).
  /// When true, the label uses normal foreground color instead of muted.
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background layer
        if (rightBackgroundColor != null)
          Positioned.fill(child: Container(color: rightBackgroundColor)),
        // Content layer (with padding)
        Padding(
          padding: widgetPaddingSm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    label,
                    style: context.theme.typography.xs.copyWith(
                      color: isActive
                          ? context.theme.colors.foreground
                          : context.theme.plotColors.muted,
                    ),
                  ),
                ),
              content,
            ],
          ),
        ),
      ],
    );
  }
}
