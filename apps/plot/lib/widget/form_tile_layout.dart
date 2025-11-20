import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'theme.dart';
import 'colour_scheme.dart';

/// Shared layout component for form tiles (FormTextField, FormSelect, FormButton).
///
/// Provides a consistent two-layer Stack structure:
/// - Background layer: splits at formTileSplitPoint (102px) with optional right background color
/// - Content layer: label (80px) + spacer (10px) + content widget
class FormTileLayout extends StatelessWidget {
  const FormTileLayout({
    required this.label,
    required this.content,
    this.rightBackgroundColor,
    this.isActive = false,
    super.key,
  });

  /// The label text displayed in the fixed-width prefix (right-aligned).
  final String label;

  /// The content widget displayed on the right side.
  final Widget content;

  /// Optional background color for the right side (content area).
  final Color? rightBackgroundColor;

  /// Whether this form tile is active (focused, hovered, or highlighted).
  /// When true, the label uses normal foreground color instead of muted.
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background layer (highlight only on right side)
        Positioned.fill(
          child: Row(
            children: [
              // Left side: label area without highlight
              Container(width: formTileSplitPoint),
              // Right side: content area with optional background color
              Expanded(
                child: Container(
                  color: rightBackgroundColor,
                ),
              ),
            ],
          ),
        ),
        // Content layer (with padding)
        Padding(
          padding: widgetPaddingSm,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: formTileLabelWidth,
                child: Text(
                  label,
                  textAlign: TextAlign.end,
                  style: context.theme.typography.sm.copyWith(
                    color: isActive ? context.colour.foreground : context.colour.muted,
                  ),
                ),
              ),
              const SizedBox(width: formTileSpacer),
              Expanded(child: content),
            ],
          ),
        ),
      ],
    );
  }
}
