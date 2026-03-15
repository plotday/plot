import 'package:web/web.dart';

void removeSplash() {
  document.getElementById('splash')?.remove();
  document.getElementById('splash-branding')?.remove();
  document.getElementById('splash-screen-style')?.remove();
  document.getElementById('splash-screen-script')?.remove();
}
