import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

String _controlSymbol() {
  return Platform.isMacOS ? '⌃' : 'Ctrl';
}

String _altSymbol() {
  return Platform.isMacOS ? '⌥' : 'Alt';
}

String _shiftSymbol() {
  return Platform.isMacOS ? '⇧' : 'Shift';
}

String _metaSymbol() {
  return Platform.isMacOS ? '⌘' : 'Win';
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
  if (key.keyLabel.length == 1 && RegExp(r'[a-z]', caseSensitive: false).hasMatch(key.keyLabel)) {
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
