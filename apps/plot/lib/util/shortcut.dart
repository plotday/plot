import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../cli_args.dart';
import 'shortcut_platform_stub.dart'
    if (dart.library.js_interop) 'shortcut_platform_web.dart';

/// Formats a ShortcutActivator into a human-readable string for display
String formatShortcut(ShortcutActivator? shortcut) {
  if (shortcut == null) return '';

  if (shortcut is SingleActivator) {
    return _formatSingleActivator(shortcut);
  }

  return '';
}

String _formatSingleActivator(SingleActivator activator) {
  final parts = <String>[];

  // Add modifier keys in standard order
  if (activator.control) {
    parts.add(_controlSymbol());
  }
  if (activator.alt) {
    parts.add(_altSymbol());
  }
  if (activator.shift) {
    parts.add(_shiftSymbol());
  }
  if (activator.meta) {
    parts.add(_metaSymbol());
  }

  // Add the main key
  parts.add(_formatKey(activator.trigger));

  return parts.join('');
}

bool _isMacOS() {
  // Screenshot Windows-emulation: show Ctrl-based shortcuts, not ⌘. Gated on the
  // debug --emulate-windows flag so it never affects real macOS users. (We can't
  // use defaultTargetPlatform here — overriding it app-wide breaks the macOS
  // host's PlatformMenuBar; see main.dart.)
  if (!kIsWeb && kDebugMode && CliArgs.emulateWindows) return false;
  if (kIsWeb) {
    return isMacOSWeb();
  }
  return defaultTargetPlatform == TargetPlatform.macOS;
}

String _controlSymbol() {
  return _isMacOS() ? '⌃' : 'Ctrl+';
}

String _altSymbol() {
  return _isMacOS() ? '⌥' : 'Alt+';
}

String _shiftSymbol() {
  return _isMacOS() ? '⇧' : 'Shift+';
}

String _metaSymbol() {
  return _isMacOS() ? '⌘' : 'Ctrl+';
}

/// Creates a SingleActivator that uses Meta (Cmd) on macOS and Control on other platforms.
///
/// Callers pass `alt: kIsWeb` to add a secondary modifier on web so the
/// shortcut doesn't collide with browser/OS chrome (e.g. ⌘N opens a new
/// browser window, which the page can't override). On macOS, however,
/// Option (Alt) is the dead-key composition modifier — pressing ⌥N produces
/// "~", so the browser reports a composed logical key (`~`) and a letter
/// shortcut bound to `keyN` never matches (and the composed character is
/// keyboard-layout dependent). On macOS we therefore use Control as the
/// secondary modifier (⌘⌃N) instead of Option; on Windows/Linux web, Alt is
/// safe and is kept (Ctrl+Alt+N).
SingleActivator platformSingleActivator(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  final useMeta = _isMacOS();
  // macOS can't use Option as the secondary modifier (dead-key composition),
  // so route the requested Alt to Control there instead.
  final controlAsSecondary = alt && useMeta;
  return SingleActivator(
    key,
    meta: useMeta,
    control: !useMeta || controlAsSecondary,
    shift: shift,
    alt: alt && !controlAsSecondary,
  );
}

String _formatKey(LogicalKeyboardKey key) {
  // Arrow keys
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';

  // Special keys
  if (key == LogicalKeyboardKey.enter) return '↵';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.tab) return '⇥';
  if (key == LogicalKeyboardKey.backspace) return '⌫';
  if (key == LogicalKeyboardKey.delete) return '⌦';
  if (key == LogicalKeyboardKey.space) return 'Space';

  // Letter keys (A-Z)
  if (key.keyLabel.length == 1 &&
      RegExp(r'[a-z]', caseSensitive: false).hasMatch(key.keyLabel)) {
    return key.keyLabel.toUpperCase();
  }

  // Number keys
  if (key.keyLabel.length == 1 && RegExp(r'[0-9]').hasMatch(key.keyLabel)) {
    return key.keyLabel;
  }

  // Function keys
  if (key.keyLabel.startsWith('F') && key.keyLabel.length <= 3) {
    return key.keyLabel;
  }

  // Default: use the key label
  return key.keyLabel;
}
