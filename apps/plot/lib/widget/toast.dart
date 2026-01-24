import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'logging.dart';

/// Extension for showing toasts with consistent styling and timing
extension ToastExtension on BuildContext {
  /// Show a toast notification
  ///
  /// Parameters:
  /// - [message]: The main message to display
  /// - [title]: Optional title (defaults to "Error" for errors, or message itself for success)
  /// - [isError]: Whether this is an error toast (uses destructive styling)
  /// - [duration]: Custom duration (defaults: 5s for errors, 3s for success)
  void showToast({
    required String message,
    String? title,
    bool isError = false,
    Duration? duration,
  }) {
    final colors = theme.colors;

    try {
      if (isError) {
        showFToast(
          context: this,
          alignment: FToastAlignment.topEnd,
          title: Text(title ?? 'Error'),
          description: Text(message),
          duration: duration ?? const Duration(seconds: 5),
          style: (style) => style.copyWith(
            decoration: style.decoration.copyWith(color: colors.destructive),
            iconStyle: style.iconStyle.copyWith(
              color: colors.destructiveForeground,
            ),
            titleTextStyle: style.titleTextStyle.copyWith(
              color: colors.destructiveForeground,
            ),
            descriptionTextStyle: style.descriptionTextStyle.copyWith(
              color: colors.destructiveForeground,
            ),
          ),
        );
      } else {
        showFToast(
          context: this,
          alignment: FToastAlignment.topEnd,
          title: Text(title ?? message),
          description: title != null ? Text(message) : null,
          duration: duration ?? const Duration(seconds: 3),
        );
      }
    } catch (e, t) {
      log.warning("Failed to show toast: $message", e, t);
    }
  }

  /// Show a toast notification that appears above all modals and barriers
  ///
  /// This uses the Overlay API directly to insert toast entries at the top
  /// of the overlay stack, ensuring they appear above modal barriers.
  ///
  /// Parameters:
  /// - [message]: The main message to display
  /// - [title]: Optional title (defaults to message itself)
  /// - [duration]: Custom duration (defaults to 3s)
  void showOverlayToast({
    required String message,
    String? title,
    Duration? duration,
  }) {
    try {
      // Get the root overlay
      final overlay = Overlay.of(this, rootOverlay: true);

      // Create the overlay entry
      late OverlayEntry entry;
      entry = OverlayEntry(
        builder: (context) => Positioned(
          top: 16,
          right: 16,
          child: SafeArea(
            child: FToast(
              title: Text(title ?? message),
              description: title != null ? Text(message) : null,
            ),
          ),
        ),
      );

      // Insert the entry
      overlay.insert(entry);

      // Auto-remove after duration
      Future.delayed(duration ?? const Duration(seconds: 3), () {
        if (entry.mounted) {
          entry.remove();
        }
      });
    } catch (e, t) {
      log.warning("Failed to show overlay toast: $message", e, t);
      // Fallback to regular toast
      showToast(message: message, title: title, duration: duration);
    }
  }
}
