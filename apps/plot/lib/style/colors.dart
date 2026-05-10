import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:equatable/equatable.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/util/theme_color.dart';
import 'package:plot/state/theme.dart';

/// OKLCH color representation for the color scheme
class OklchColours {
  final RayOklch background;
  final RayOklch editableBackground;
  final RayOklch accent;
  final RayOklch accentBackground;
  final RayOklch highlight;
  final RayOklch foreground;
  final RayOklch muted;
  final RayOklch veryMuted;
  final RayOklch border;
  final RayOklch barrier;
  final RayOklch pureBackground;
  final RayOklch pureForeground;

  /// The ThemeColor used to create this colour scheme
  final ThemeColor _themeColor;

  /// The brightness used to create this colour scheme
  final Brightness _brightness;

  /// The saturate factor applied during creation
  final double _saturate;

  const OklchColours({
    required this.background,
    required this.editableBackground,
    required this.accent,
    required this.accentBackground,
    required this.highlight,
    required this.foreground,
    required this.muted,
    required this.veryMuted,
    required this.border,
    required this.barrier,
    required this.pureBackground,
    required this.pureForeground,
    required ThemeColor themeColor,
    required Brightness brightness,
    required double saturate,
  }) : _themeColor = themeColor,
       _brightness = brightness,
       _saturate = saturate;

  /// Calculate accent lightness for a ThemeColor based on brightness.
  /// Per-color tuning: warm yellow/gold hues need higher lightness to avoid
  /// looking brown, while gray needs lower lightness for contrast.
  static double _getAccentLightness(
    ThemeColor? themeColor,
    Brightness brightness,
  ) {
    return switch (themeColor?.index) {
      5 =>
        brightness == Brightness.light
            ? 0.43
            : 0.80, // orange: boost to avoid brown
      6 =>
        brightness == Brightness.light
            ? 0.46
            : 0.80, // yellow: needs most boost to avoid olive
      7 =>
        brightness == Brightness.light
            ? 0.30
            : 0.82, // gray: lower for contrast
      _ => brightness == Brightness.light ? 0.38 : 0.78,
    };
  }

  /// Create OKLCH colors from a ThemeColor
  factory OklchColours.fromThemeColor({
    required ThemeColor themeColor,
    required Brightness brightness,
    double darken = 1.0,
    double saturate = 1.0,
  }) {
    final hue = themeColor.toHue();
    final isDark = brightness == Brightness.dark;
    final accentChroma = themeColor.toChroma(isDark: isDark);

    /// Accent-hued color — chroma is the per-color value, scaled by saturate
    /// and darken adjustments.
    RayOklch lch(double l, double c, [double? h, double? o]) {
      return RayOklch.fromComponents(
        (l / darken).clamp(0.0, 1.0),
        c * saturate * (brightness == Brightness.light ? darken : 1 / darken),
        h ?? hue,
        o ?? 1.0,
      );
    }

    /// Warm neutral color — fixed warm hue, independent of priority color.
    /// Chroma is fixed (not scaled by darken) so darker surfaces don't become
    /// more saturated.
    RayOklch neutral(double l, double c, [double? h, double? o]) {
      return RayOklch.fromComponents(
        (l / darken).clamp(0.0, 1.0),
        c * saturate,
        h ?? 115.0,
        o ?? 1.0,
      );
    }

    // Pure white and black
    final pureBackground = brightness == .light
        ? RayOklch.fromComponents(1.0, 0.0, 0.0)
        : RayOklch.fromComponents(0.0, 0.0, 0.0);
    final pureForeground = brightness == .light
        ? RayOklch.fromComponents(0.0, 0.0, 0.0)
        : RayOklch.fromComponents(1.0, 0.0, 0.0);

    if (brightness == Brightness.light) {
      final accentLightness = _getAccentLightness(themeColor, brightness);
      return OklchColours(
        pureBackground: pureBackground,
        pureForeground: pureForeground,
        background: neutral(0.98, 0.01),
        editableBackground: neutral(1.0, 0),
        accent: lch(accentLightness, accentChroma),
        accentBackground: lch(
          themeColor.index == 7 ? 0.93 : 0.96,
          accentChroma * 0.25,
        ),
        highlight: neutral(0.94, 0.03, null, 0.9),
        foreground: neutral(0.25, 0.01),
        muted: neutral(0.48, 0.01),
        veryMuted: neutral(0.58, 0.01),
        border: neutral(0.0, 0.0, 0.0, 0.18),
        barrier: neutral(0.0, 0.0, 0.0, 0.3),
        themeColor: themeColor,
        brightness: brightness,
        saturate: saturate,
      );
    } else {
      final accentLightness = _getAccentLightness(themeColor, brightness);
      return OklchColours(
        pureBackground: pureBackground,
        pureForeground: pureForeground,
        background: neutral(0.26, 0.006),
        editableBackground: neutral(0.30, 0.006),
        accent: lch(accentLightness, accentChroma),
        accentBackground: lch(0.24, accentChroma * 0.31),
        highlight: neutral(0.5, 0.010, null, 0.14),
        foreground: neutral(0.88, 0.004),
        muted: neutral(0.65, 0.006),
        veryMuted: neutral(0.48, 0.005),
        border: neutral(1.0, 0.0, 0.0, 0.12),
        barrier: neutral(0.0, 0.0, 0.0, 0.6),
        themeColor: themeColor,
        brightness: brightness,
        saturate: saturate,
      );
    }
  }

  Color fromTheme(ThemeColor? color, {double? lightness, bool muted = false}) {
    double effectiveLightness;
    double chromaMultiplier = 1.0;
    final isDark = _brightness == Brightness.dark;
    final c = color ?? const ThemeColor.defaultColor();

    if (muted) {
      effectiveLightness = isDark ? 0.68 : 0.55;
      chromaMultiplier = 0.5;
    } else if (lightness != null) {
      effectiveLightness = lightness;
    } else {
      effectiveLightness = _getAccentLightness(color, _brightness);
    }

    return RayOklch.fromComponents(
      effectiveLightness,
      c.toChroma(isDark: isDark) * _saturate * chromaMultiplier,
      c.toHue(),
    ).toColor();
  }

  /// Subtle tinted background for a given priority color, matching
  /// [accentBackground] but with the target color's hue and per-color chroma.
  Color backgroundFromTheme(ThemeColor? color) {
    final c = color ?? const ThemeColor.defaultColor();
    final isDark = _brightness == Brightness.dark;
    final currentChroma = _themeColor.toChroma(isDark: isDark);
    final targetChroma = c.toChroma(isDark: isDark);
    final chromaScale = currentChroma > 0 ? targetChroma / currentChroma : 0.0;
    return accentBackground
        .withHue(c.toHue())
        .withChroma(accentBackground.chroma * chromaScale)
        .toColor();
  }
}

class ColourSchemeData extends Equatable {
  final ThemeColor themeColor;
  final Brightness brightness;
  final double darken;
  final double saturate;
  final OklchColours _colours;

  /// Get the OKLCH colours
  OklchColours get colours => _colours;

  /// Create a color scheme from a ThemeColor
  ColourSchemeData({
    required this.themeColor,
    required this.brightness,
    this.darken = 1.0,
    this.saturate = 1.0,
  }) : _colours = OklchColours.fromThemeColor(
         themeColor: themeColor,
         brightness: brightness,
         darken: darken,
         saturate: saturate,
       );

  ColourSchemeData copyWith({
    ThemeColor? themeColor,
    Brightness? brightness,
    double? darken,
    double? saturate,
  }) {
    return ColourSchemeData(
      themeColor: themeColor ?? this.themeColor,
      brightness: brightness ?? this.brightness,
      darken: darken != null ? darken * this.darken : this.darken,
      saturate: saturate != null ? saturate * this.saturate : this.saturate,
    );
  }

  /// Background color darkened by 3 steps, matching the unified section
  /// header background shared by agenda date headers, agenda gap headers,
  /// PriorityPage activity-feed section headers ("Today"/"New"/...), and
  /// PrioritiesPage section headers ("Top Priorities"/"All Priorities").
  Color get headerBackground {
    final factor = brightness == Brightness.light ? 1.015 : 1.05;
    return copyWith(darken: pow(factor, 3).toDouble()).background;
  }

  Color get barrier => _colours.barrier.toColor();
  Color get background => _colours.background.toColor();
  Color get editableBackground => _colours.editableBackground.toColor();
  Color get accent => _colours.accent.toColor();
  Color get accentBackground => _colours.accentBackground.toColor();
  Color get highlight => _colours.highlight.toColor();
  Color get foreground => _colours.foreground.toColor();
  Color get muted => _colours.muted.toColor();
  Color get veryMuted => _colours.veryMuted.toColor();
  Color get border => _colours.border.toColor();

  FColors toFColorScheme() {
    return FColors(
      brightness: brightness,
      barrier: barrier,
      background: background,
      foreground: foreground,
      primary: accent,
      primaryForeground: accentBackground,
      secondary: highlight,
      secondaryForeground: foreground,
      muted: const Color(0x00FFFFFF),
      mutedForeground: muted,
      destructive: RayOklch.fromComponents(
        brightness == Brightness.light ? 0.2 : 0.65,
        brightness == Brightness.light ? 0.8 : 0.15,
        25.72,
      ).toColor(),
      destructiveForeground: brightness == Brightness.light
          ? const Color(0xFFFAFAFA)
          : const Color(0xFFFAFAFA),
      error: RayOklch.fromComponents(
        brightness == Brightness.light ? 0.2 : 0.65,
        brightness == Brightness.light ? 0.8 : 0.2,
        25.72,
      ).toColor(),
      errorForeground: brightness == Brightness.light
          ? const Color(0xFFFAFAFA)
          : const Color(0xFFFAFAFA),
      card: background,
      border: border,
      disabledOpacity: 0.5,
      systemOverlayStyle: brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
    );
  }

  @override
  List<Object?> get props => [themeColor, brightness, darken, saturate];
}

class ColourScheme extends StatefulWidget {
  /// Default brand hue (teal/green ~160 degrees)
  static const double defaultHue = 160.0;

  final Widget child;

  const ColourScheme({required this.child, super.key});

  @override
  State<ColourScheme> createState() => _ColourSchemeState();
}

class _ColourSchemeState extends State<ColourScheme>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    // Trigger rebuild when system theme changes
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeBloc, ThemeState>(
      builder: (context, themeState) {
        final brightness = context.read<ThemeBloc>().getBrightness(context);
        return ProxyProvider0(
          update: (_, _) => ColourSchemeData(
            themeColor: themeState.priorityColor,
            brightness: brightness,
          ),
          child: widget.child,
        );
      },
    );
  }
}

extension ColourSchemeExtension on BuildContext {
  ColourSchemeData get colour {
    return Provider.of<ColourSchemeData>(this, listen: true);
  }

  ColourSchemeData get colourOnce {
    return Provider.of<ColourSchemeData>(this, listen: false);
  }
}
