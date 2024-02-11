export 'google_sign_in_button_native.dart'
    if (dart.library.js_util) 'google_sign_in_button_web.dart';

export 'google_sign_in_native_shims.dart'
    if (dart.library.js_util) 'package:google_sign_in_web/web_only.dart';
