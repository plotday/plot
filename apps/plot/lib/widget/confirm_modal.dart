import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'list_tile.dart';
import 'select_modal.dart';

/// Three-way outcome of a [ConfirmModal]: the confirm button, the cancel
/// button, or dismissal (Esc / tapping outside). Callers that only care about
/// confirm-vs-not can keep using [ConfirmModal.run].
enum ConfirmOutcome { confirmed, cancelled, dismissed }

/// A standard confirm/cancel dialog, implemented as a [SelectModal] so it
/// gets Plot's standard modal styling, stacking via `ModalProvider`, and
/// keyboard navigation (↑/↓/Enter/Esc) for free.
///
/// [run] returns `true` when confirmed, `false` when cancelled or dismissed.
class ConfirmModal {
  const ConfirmModal({
    required this.title,
    this.message,
    this.messageWidget,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
  }) : assert(
         message != null || messageWidget != null,
         'ConfirmModal needs a message or a messageWidget',
       );

  final String title;
  final String? message;

  /// Optional rich message rendered instead of [message] (e.g. tappable
  /// links). Takes precedence over [message] when both are provided.
  final Widget? messageWidget;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  Future<ConfirmOutcome> runDetailed(BuildContext context) async {
    // Cancel (false) is listed first so it starts highlighted — the safer
    // default, especially for destructive confirmations.
    final result = await SelectModal.open<bool>(
      context,
      showFilter: false,
      title: title,
      subtitle: messageWidget == null ? message : null,
      subtitleWidget: messageWidget,
      selectedValue: false,
      items: (_) async => [
        SelectGroup<bool>(items: const [false, true]),
      ],
      itemBuilder: (value, _) => Builder(
        builder: (context) {
          final isDestructiveConfirm = value && destructive;
          return ListTile(
            title: value ? confirmLabel : cancelLabel,
            textStyle: isDestructiveConfirm
                ? TextStyle(color: context.theme.colors.destructive)
                : null,
          );
        },
      ),
    );
    if (!result.present) return ConfirmOutcome.dismissed;
    return result.value == true
        ? ConfirmOutcome.confirmed
        : ConfirmOutcome.cancelled;
  }

  /// Convenience wrapper: true only when the user picked the confirm action.
  Future<bool> run(BuildContext context) async =>
      (await runDetailed(context)) == ConfirmOutcome.confirmed;
}
