import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'list_tile.dart';
import 'select_modal.dart';

/// A standard confirm/cancel dialog, implemented as a [SelectModal] so it
/// gets Plot's standard modal styling, stacking via `ModalProvider`, and
/// keyboard navigation (↑/↓/Enter/Esc) for free.
///
/// [run] returns `true` when confirmed, `false` when cancelled or dismissed.
class ConfirmModal {
  const ConfirmModal({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  Future<bool> run(BuildContext context) async {
    // Cancel (false) is listed first so it starts highlighted — the safer
    // default, especially for destructive confirmations.
    final result = await SelectModal.open<bool>(
      context,
      showFilter: false,
      title: title,
      subtitle: message,
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
    return result.present && result.value == true;
  }
}
