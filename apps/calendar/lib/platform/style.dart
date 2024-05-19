import 'dart:io';
import 'package:flutter/foundation.dart';

enum Style {
  mac,
  ios,
  material,
  windows,
}

Style _getStyle() {
  if (kIsWeb) {
    return Style.material;
  }
  if (Platform.isMacOS) {
    return Style.mac;
  } else if (Platform.isIOS) {
    return Style.ios;
  } else if (Platform.isWindows) {
    return Style.windows;
  } else {
    return Style.material;
  }
}

Style style = _getStyle();
