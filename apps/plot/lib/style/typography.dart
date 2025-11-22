import 'package:forui/forui.dart';

FTypography buildTypography(FColors colorScheme) {
  return FTypography.inherit(
    colors: colorScheme,
    defaultFontFamily: 'Figtree',
  ).copyWith(
    xs: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 9),
    sm: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 10.5),
    base: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: 12),
  );
}
