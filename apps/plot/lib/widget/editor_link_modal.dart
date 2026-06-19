import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/spacing.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/text_field_selection_theme.dart';
import 'icon.dart';
import 'modal.dart';

/// Result from the link modal
sealed class LinkModalResult {}

class LinkModalApply extends LinkModalResult {
  LinkModalApply(this.url);
  final String url;
}

class LinkModalRemove extends LinkModalResult {}

/// A modal for entering or editing a URL for inline links.
class EditorLinkModal extends Modal {
  EditorLinkModal({this.existingUrl, super.key})
    : super(
        constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
        padding: const EdgeInsets.all(16),
        builder: (context) => _EditorLinkModalContent(existingUrl: existingUrl),
      );

  final String? existingUrl;

  Future<LinkModalResult?> run(BuildContext context) {
    return super
        .show<LinkModalResult>(context)
        .then((value) => value.present ? value.value : null);
  }
}

class _EditorLinkModalContent extends StatefulWidget {
  const _EditorLinkModalContent({this.existingUrl});

  final String? existingUrl;

  @override
  State<_EditorLinkModalContent> createState() =>
      _EditorLinkModalContentState();
}

class _EditorLinkModalContentState extends State<_EditorLinkModalContent> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.existingUrl ?? '');
    _focusNode = FocusNode();

    // Auto-focus the text field
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        // Select all text if editing existing URL
        if (widget.existingUrl != null) {
          _controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _controller.text.length,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _controller.text.trim();
    if (url.isNotEmpty) {
      Modal.pop<LinkModalResult>(
        context,
        Value<LinkModalResult>(LinkModalApply(url)),
      );
    }
  }

  void _removeLink() {
    Modal.pop<LinkModalResult>(
      context,
      Value<LinkModalResult>(LinkModalRemove()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final spacing = theme.spacing;
    final isEditing = widget.existingUrl != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Reserve space for the floating close button rendered by [Modal].
          padding: const EdgeInsets.only(
            right: modalCloseButtonReservedWidth,
          ),
          child: Text(
            isEditing ? 'Edit link' : 'Add link',
            style: theme.typography.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(height: spacing.md),
        FTextField(
          builder: fieldSelectionBuilder,
          control: .managed(controller: _controller),
          hint: 'https://',
          focusNode: _focusNode,
          autocorrect: false,
          onSubmit: (_) => _submit(),
        ),
        SizedBox(height: spacing.md),
        Row(
          children: [
            if (isEditing) ...[
              GestureDetector(
                onTap: _removeLink,
                child: Text(
                  'Remove link',
                  style: theme.typography.sm.copyWith(
                    color: theme.colors.destructive,
                  ),
                ),
              ),
              const Spacer(),
            ] else
              const Spacer(),
            GestureDetector(
              onTap: _submit,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: spacing.lg,
                  vertical: spacing.sm,
                ),
                decoration: BoxDecoration(
                  color: theme.colors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      PlotIcon.save,
                      size: 13,
                      color: theme.colors.primaryForeground,
                    ),
                    SizedBox(width: spacing.xs),
                    Text(
                      'Apply',
                      style: theme.typography.sm.copyWith(
                        color: theme.colors.primaryForeground,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
