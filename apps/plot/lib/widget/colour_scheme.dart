import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:equatable/equatable.dart';
import 'package:forui/forui.dart';

class ColourSchemeData extends Equatable {
  final HSLColor base;
  final HSLColor pureBackground;
  final HSLColor pureForeground;
  final Brightness brightness;

  ColourSchemeData(Color base, this.brightness)
    : base = HSLColor.fromColor(base).withAlpha(1),
      pureBackground =
          brightness == Brightness.light
              ? HSLColor.fromColor(Color(0xFFFFFFFF))
              : HSLColor.fromColor(Color(0xFF000000)),
      pureForeground =
          brightness == Brightness.light
              ? HSLColor.fromColor(Color(0xFF000000))
              : HSLColor.fromColor(Color(0xFFFFFFFF));

  Color get barrier => pureBackground.withAlpha(0.6).toColor();
  Color get canvas =>
      brightness == Brightness.light
          ? base.withLightness(0.9).withAlpha(0.9).toColor()
          : base.withLightness(0.15).withAlpha(0.25).toColor();
  Color get background =>
      brightness == Brightness.light
          ? base.withLightness(0.9).withAlpha(0.9).toColor()
          : base.withSaturation(0.2).withLightness(0.08).toColor();
  Color get modalBackground =>
      brightness == Brightness.light
          ? base.withLightness(0.9).withAlpha(0.9).toColor()
          : base.withSaturation(0.3).withLightness(0.12).toColor();
  Color get editableBackground =>
      brightness == Brightness.light
          ? base.withLightness(0.9).withAlpha(0.9).toColor()
          : base.withSaturation(0.1).withLightness(0.12).toColor();
  Color get accent =>
      brightness == Brightness.light
          ? base.withLightness(0.6).toColor()
          : base.withLightness(0.4).toColor();
  Color get accentBackground =>
      brightness == Brightness.light
          ? base.withLightness(0.7).toColor()
          : base.withLightness(0.35).toColor();
  Color get highlight =>
      brightness == Brightness.light
          ? base.withLightness(0.9).toColor()
          : base.withLightness(0.15).withAlpha(0.4).toColor();
  Color get border =>
      brightness == Brightness.light
          ? pureForeground.withAlpha(0.2).toColor()
          : pureForeground.withAlpha(0.1).toColor();
  Color get foreground =>
      brightness == Brightness.light ? Color(0xFF000000) : Color(0xFFFFFFFF);
  Color get muted =>
      brightness == Brightness.light
          ? base.withSaturation(0.2).withLightness(0.2).toColor()
          : base.withSaturation(0.2).withLightness(0.7).toColor();

  FColors toFColorScheme() {
    return FColors(
      brightness: brightness,
      barrier: barrier,
      background: background,
      foreground: foreground,
      primary: accentBackground,
      primaryForeground: foreground,
      secondary: highlight,
      secondaryForeground: foreground,
      muted: Color(0x00FFFFFF),
      mutedForeground: muted,
      destructive:
          brightness == Brightness.light
              ? Color(0xFFEF4444)
              : Color(0xFF7F1D1D),
      destructiveForeground:
          brightness == Brightness.light
              ? Color(0xFFFAFAFA)
              : Color(0xFFFAFAFA),
      error:
          brightness == Brightness.light
              ? Color(0xFFEF4444)
              : Color(0xFF7F1D1D),
      errorForeground:
          brightness == Brightness.light
              ? Color(0xFFFAFAFA)
              : Color(0xFFFAFAFA),
      border: border,
      enabledHoveredOpacity: 0.9,
      disabledOpacity: 0.5,
      systemOverlayStyle: brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
    );
  }

  @override
  List<Object?> get props => [base, brightness];
}

class ColourScheme extends StatelessWidget {
  static const Color brand = Color.fromARGB(255, 35, 152, 112);

  final Widget child;
  final Color base;

  const ColourScheme({this.base = brand, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    return ProxyProvider0(
      update: (_, __) => ColourSchemeData(base, brightness),
      child: child,
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
