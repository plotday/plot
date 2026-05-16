import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/spacing.dart';
import 'package:plot/util/value.dart';
import 'modal.dart';

/// Result from [EditLinkModal] — the new title and URL the user submitted.
class EditLinkResult {
  EditLinkResult({required this.title, required this.url});

  final String title;
  final String url;
}

/// Modal for editing both the title and URL of an existing link. Used by the
/// pinned-link menu and by the menu on link buttons attached to notes.
class EditLinkModal extends Modal {
  EditLinkModal({
    required this.initialTitle,
    required this.initialUrl,
    super.key,
  }) : super(
         constraints: const BoxConstraints(maxHeight: 280, maxWidth: 440),
         padding: const EdgeInsets.all(16),
         builder: (context) => _EditLinkModalContent(
           initialTitle: initialTitle,
           initialUrl: initialUrl,
         ),
       );

  final String initialTitle;
  final String initialUrl;

  Future<EditLinkResult?> run(BuildContext context) {
    return super
        .show<EditLinkResult>(context)
        .then((value) => value.present ? value.value : null);
  }
}

class _EditLinkModalContent extends StatefulWidget {
  const _EditLinkModalContent({
    required this.initialTitle,
    required this.initialUrl,
  });

  final String initialTitle;
  final String initialUrl;

  @override
  State<_EditLinkModalContent> createState() => _EditLinkModalContentState();
}

class _EditLinkModalContentState extends State<_EditLinkModalContent> {
  late final TextEditingController _titleController;
  late final TextEditingController _urlController;
  late final FocusNode _titleFocus;
  late final FocusNode _urlFocus;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _urlController = TextEditingController(text: widget.initialUrl);
    _titleFocus = FocusNode();
    _urlFocus = FocusNode();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _titleFocus.requestFocus();
      _titleController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _titleController.text.length,
      );
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _urlController.dispose();
    _titleFocus.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final title = _titleController.text.trim();
    Modal.pop<EditLinkResult>(
      context,
      Value<EditLinkResult>(EditLinkResult(title: title, url: url)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final spacing = theme.spacing;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: modalCloseButtonReservedWidth),
          child: Text(
            'Edit link',
            style: theme.typography.md.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(height: spacing.md),
        Text(
          'Title',
          style: theme.typography.xs.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        SizedBox(height: spacing.xs),
        FTextField(
          control: .managed(controller: _titleController),
          hint: 'Title',
          focusNode: _titleFocus,
          autocorrect: false,
          onSubmit: (_) => _urlFocus.requestFocus(),
        ),
        SizedBox(height: spacing.md),
        Text(
          'Link',
          style: theme.typography.xs.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        SizedBox(height: spacing.xs),
        FTextField(
          control: .managed(controller: _urlController),
          hint: 'https://',
          focusNode: _urlFocus,
          autocorrect: false,
          onSubmit: (_) => _submit(),
        ),
        SizedBox(height: spacing.lg),
        Row(
          children: [
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
                child: Text(
                  'Save',
                  style: theme.typography.sm.copyWith(
                    color: theme.colors.primaryForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
