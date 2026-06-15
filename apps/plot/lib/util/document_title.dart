// Sets the browser-tab title on web; a no-op everywhere else.
//
// Mirrors the project's conditional-import idiom (see `splash.dart`): the web
// implementation uses `package:web` `document.title`, while non-web builds get
// the stub so `package:web` is never reached off the web.
export 'document_title_stub.dart'
    if (dart.library.js_interop) 'document_title_web.dart';
