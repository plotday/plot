import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor_spellcheck/super_editor_spellcheck.dart';

/// Plot-themed spelling suggestion toolbar. Replaces the plugin's default
/// (Material-styled, white in dark mode) toolbar with one that uses forui
/// theme colors and Plot's typography.
class EditorSpellingToolbar extends StatefulWidget {
  const EditorSpellingToolbar({
    super.key,
    required this.editorFocusNode,
    required this.editor,
    required this.selectedWordRange,
    required this.suggestions,
    required this.closeToolbar,
  });

  final FocusNode editorFocusNode;
  final Editor editor;
  final DocumentRange? selectedWordRange;
  final List<String> suggestions;
  final VoidCallback closeToolbar;

  @override
  State<EditorSpellingToolbar> createState() => _EditorSpellingToolbarState();
}

class _EditorSpellingToolbarState extends State<EditorSpellingToolbar> {
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    widget.editor.document.addListener(_onDocumentChange);
  }

  @override
  void didUpdateWidget(covariant EditorSpellingToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editor.document != oldWidget.editor.document) {
      oldWidget.editor.document.removeListener(_onDocumentChange);
      widget.editor.document.addListener(_onDocumentChange);
    }
  }

  @override
  void dispose() {
    widget.editor.document.removeListener(_onDocumentChange);
    super.dispose();
  }

  void _onDocumentChange(DocumentChangeLog _) => widget.closeToolbar();

  void _apply(String replacement) {
    final range = widget.selectedWordRange;
    if (range == null) return;
    widget.editor.fixMisspelledWord(range, replacement);
    widget.closeToolbar();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    // The plugin's overlay positioner hard-codes a 16px gap below the word.
    // Pull the toolbar up so the relationship to the underlined error reads
    // tighter.
    return Transform.translate(
      offset: const Offset(0, -10),
      child: Focus(
        parentNode: widget.editorFocusNode,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colors.background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: theme.colors.border, width: 1),
            boxShadow: [
              BoxShadow(
                color: theme.colors.foreground.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < widget.suggestions.length; i++) ...[
                    if (i > 0)
                      Container(width: 1, color: theme.colors.border),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _hoveredIndex = i),
                      onExit: (_) => setState(() => _hoveredIndex = null),
                      child: GestureDetector(
                        onTap: () => _apply(widget.suggestions[i]),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          color: _hoveredIndex == i
                              ? theme.colors.secondary
                              : null,
                          child: Text(
                            widget.suggestions[i],
                            style: theme.typography.sm.copyWith(
                              color: theme.colors.foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Builder that satisfies [SpellingErrorSuggestionToolbarBuilder] for the
/// `super_editor_spellcheck` plugin.
Widget editorSpellingToolbarBuilder(
  BuildContext context, {
  required FocusNode editorFocusNode,
  required Editor editor,
  required DocumentLayout documentLayout,
  required DocumentRange selectedWordRange,
  required List<String> suggestions,
  required VoidCallback onCancelPressed,
  required VoidCallback closeToolbar,
}) {
  return EditorSpellingToolbar(
    editorFocusNode: editorFocusNode,
    editor: editor,
    selectedWordRange: selectedWordRange,
    suggestions: suggestions,
    closeToolbar: closeToolbar,
  );
}
