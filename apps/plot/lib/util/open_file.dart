/// Opens downloaded file bytes with the platform's default handler.
///
/// The implementation is platform-split so web builds never pull in `dart:io`
/// or the mobile-only `open_filex` plugin (mirrors `download.dart`).
library;

export 'open_file_io.dart'
    if (dart.library.js_interop) 'open_file_web.dart';
