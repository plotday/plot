import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
SingleActivator platformSingleActivator(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  final useMeta = _isMacOS();
  return SingleActivator(
    key,
    meta: useMeta,
    control: !useMeta,
    shift: shift,
    alt: alt,
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
