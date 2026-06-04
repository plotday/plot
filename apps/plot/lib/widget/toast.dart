import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/toaster.dart';

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
    // Read the colour scheme without listening: showToast is invoked from
    // imperative event handlers (keyboard shortcuts, taps), where a listening
    // `Provider.of` (context.colour) throws "Tried to listen to a value
    // exposed with provider, from outside of the widget tree" and aborts the
    // toast before it can be shown.
    final destructiveFg = destructiveToastForeground(colourOnce);

    try {
      if (isError) {
        showFToast(
          context: this,
          alignment: FToastAlignment.topEnd,
          title: Text(title ?? 'Error'),
          description: Text(message),
          duration: duration ?? const Duration(seconds: 5),
          variant: FToastVariant.destructive,
          suffixBuilder: (context, entry) => _CopyButton(
            text: message,
            color: destructiveFg,
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
  /// - [title]: Optional title (defaults to "Error" for errors, or message itself for success)
  /// - [isError]: Whether this is an error toast (uses destructive styling)
  /// - [duration]: Custom duration (defaults: 5s for errors, 3s for success)
  void showOverlayToast({
    required String message,
    String? title,
    bool isError = false,
    Duration? duration,
  }) {
    // listen: false — see showToast above; this runs from event handlers too.
    final destructiveFg = destructiveToastForeground(colourOnce);

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
              variant: isError ? FToastVariant.destructive : FToastVariant.primary,
              title: Text(isError ? (title ?? 'Error') : (title ?? message)),
              description: isError
                  ? Text(message)
                  : (title != null ? Text(message) : null),
              suffix: isError
                  ? _CopyButton(
                      text: message,
                      color: destructiveFg,
                    )
                  : null,
            ),
          ),
        ),
      );

      // Insert the entry
      overlay.insert(entry);

      // Auto-remove after duration
      final defaultDuration =
          isError ? const Duration(seconds: 5) : const Duration(seconds: 3);
      Future.delayed(duration ?? defaultDuration, () {
        try {
          entry.remove();
        } catch (_) {}
      });
    } catch (e, t) {
      log.warning("Failed to show overlay toast: $message", e, t);
      // Fallback to regular toast
      showToast(message: message, title: title, isError: isError, duration: duration);
    }
  }
}

class _CopyButton extends StatefulWidget {
  final String text;
  final Color color;

  const _CopyButton({required this.text, required this.color});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: widget.text));
        setState(() => _copied = true);
      },
      child: Icon(
        _copied ? FontAwesomeIcons.check : FontAwesomeIcons.copy,
        size: 14,
        color: widget.color,
      ),
    );
  }
}
