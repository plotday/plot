import 'package:flutter/material.dart' show ThemeExtension;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

class PlotColors extends ThemeExtension<PlotColors> {
  final Color barrier;
  final Color muted;
  final Color veryMuted;
  final Color highlight;
  final Color editableBackground;

  const PlotColors({
    required this.barrier,
    required this.muted,
    required this.veryMuted,
    required this.highlight,
    required this.editableBackground,
  });

  @override
  PlotColors copyWith({
    Color? barrier,
    Color? muted,
    Color? veryMuted,
    Color? highlight,
    Color? editableBackground,
  }) => PlotColors(
    barrier: barrier ?? this.barrier,
    muted: muted ?? this.muted,
    veryMuted: veryMuted ?? this.veryMuted,
    highlight: highlight ?? this.highlight,
    editableBackground: editableBackground ?? this.editableBackground,
  );

  @override
  PlotColors lerp(PlotColors? other, double t) {
    if (other is! PlotColors) {
      return this;
    }

    return PlotColors(
      barrier: Color.lerp(barrier, other.barrier, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      veryMuted: Color.lerp(veryMuted, other.veryMuted, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      editableBackground: Color.lerp(
        editableBackground,
        other.editableBackground,
        t,
      )!,
    );
  }
}

extension PlotColorsExtension on FThemeData {
  PlotColors get plotColors => extension<PlotColors>();
}
