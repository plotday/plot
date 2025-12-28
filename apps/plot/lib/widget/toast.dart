import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

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
  }
}
