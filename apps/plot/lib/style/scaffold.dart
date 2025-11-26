import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

FScaffoldStyle scaffoldStyle({
  required FColors colors,
  required FStyle style,
}) => FScaffoldStyle(
  systemOverlayStyle: colors.systemOverlayStyle,
  backgroundColor: colors.background,
  sidebarBackgroundColor: colors.background,
  childPadding: style.pagePadding.copyWith(top: 0, bottom: 16),
  footerDecoration: BoxDecoration(
    border: Border(
      top: BorderSide(color: colors.border, width: style.borderWidth),
    ),
  ),
  headerDecoration: const BoxDecoration(),
);
