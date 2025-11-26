import 'package:forui/forui.dart';

FTypography buildTypography(FColors colorScheme) {
  return FTypography.inherit(
    colors: colorScheme,
    defaultFontFamily: 'Figtree',
  ).copyWith(
    xs: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 11),
    sm: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 13),
    base: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 15),
    lg: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 18),
    xl: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 22),
  );
}
