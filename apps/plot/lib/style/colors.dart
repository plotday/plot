import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:equatable/equatable.dart';
import 'package:forui/forui.dart';
import '../state/theme.dart';

class ColourSchemeData extends Equatable {
  final HSLColor base;
  final HSLColor pureBackground;
  final HSLColor pureForeground;
  final Brightness brightness;

  ColourSchemeData(Color base, this.brightness)
    : base = HSLColor.fromColor(base).withAlpha(1),
      pureBackground = brightness == Brightness.light
          ? HSLColor.fromColor(Color(0xFFFFFFFF))
          : HSLColor.fromColor(Color(0xFF000000)),
      pureForeground = brightness == Brightness.light
          ? HSLColor.fromColor(Color(0xFF000000))
          : HSLColor.fromColor(Color(0xFFFFFFFF));

  Color get barrier => HSLColor.fromColor(
    Color(0xFF000000),
  ).withAlpha(brightness == Brightness.light ? 0.3 : 0.6).toColor();
  Color get background => _background.toColor();
  HSLColor get _background => brightness == Brightness.light
      ? base
            .withHue((base.hue - 100) % 360)
            .withSaturation(0.2)
            .withLightness(0.95)
      : base
            .withHue((base.hue - 100) % 360)
            .withSaturation(0.05)
            .withLightness(0.12);
  Color get modalBackground => brightness == Brightness.light
      ? base
            .withHue((base.hue - 100) % 360)
            .withSaturation(0.2)
            .withLightness(0.985)
            .toColor()
      : base.withSaturation(0.15).withLightness(0.12).toColor();
  Color get editableBackground => brightness == Brightness.light
      ? base.withLightness(0.99).toColor()
      : _background.withLightness(0.16).toColor();
  Color get accent => brightness == Brightness.light
      ? base.withSaturation(0.8).withLightness(0.3).toColor()
      : base.withSaturation(0.4).withLightness(0.55).toColor();
  Color get accentBackground => brightness == Brightness.light
      ? base
            .withHue((base.hue - 35) % 360)
            .withSaturation(0.3)
            .withLightness(0.94)
            .toColor()
      : base
            .withHue((base.hue - 35) % 360)
            .withSaturation(0.1)
            .withLightness(0.10)
            .toColor();
  Color get highlight => brightness == Brightness.light
      ? _background.withLightness(0.91).toColor()
      : _background.withLightness(0.095).toColor();
  Color get border => brightness == Brightness.light
      ? pureForeground.withAlpha(0.1).toColor()
      : pureForeground.withAlpha(0.1).toColor();
  Color get foreground => brightness == Brightness.light
      ? base.withSaturation(0.1).withLightness(0.1).toColor()
      : Color(0xFFFFFFFF);
  Color get muted => brightness == Brightness.light
      ? base.withSaturation(0.1).withLightness(0.35).toColor()
      : base.withSaturation(0.07).withLightness(0.7).toColor();

  FColors toFColorScheme() {
    return FColors(
      brightness: brightness,
      barrier: barrier,
      background: background,
      foreground: foreground,
      primary: accentBackground,
      primaryForeground: accent,
      secondary: highlight,
      secondaryForeground: foreground,
      muted: Color(0x00FFFFFF),
      mutedForeground: muted,
      destructive: brightness == Brightness.light
          ? Color(0xFFEF4444)
          : Color(0xFF7F1D1D),
      destructiveForeground: brightness == Brightness.light
          ? Color(0xFFFAFAFA)
          : Color(0xFFFAFAFA),
      error: brightness == Brightness.light
          ? Color(0xFFEF4444)
          : Color(0xFF7F1D1D),
      errorForeground: brightness == Brightness.light
          ? Color(0xFFFAFAFA)
          : Color(0xFFFAFAFA),
      border: border,
      disabledOpacity: 0.5,
      systemOverlayStyle: brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
    );
  }

  @override
  List<Object?> get props => [base, brightness];
}

class ColourScheme extends StatefulWidget {
  static const Color brand = Color.fromARGB(255, 35, 152, 112);

  final Widget child;
  final Color base;

  const ColourScheme({this.base = brand, required this.child, super.key});

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

  Brightness _getEffectiveBrightness(BuildContext context, AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.light => Brightness.light,
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeBloc, ThemeState>(
      builder: (context, themeState) {
        final brightness = _getEffectiveBrightness(context, themeState.mode);
        return ProxyProvider0(
          update: (_, _) => ColourSchemeData(widget.base, brightness),
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
