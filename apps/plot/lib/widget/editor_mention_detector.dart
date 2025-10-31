import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import 'editor_mention_plugin.dart';

/// A class that detects when a user starts typing a mention (starting with "@")
/// and provides information about the composing mention.
class EditorMentionDetector extends ChangeNotifier {
  EditorMentionDetector({
    required MutableDocument document,
    required MutableDocumentComposer composer,
    required Editor editor,
  }) : _document = document,
       _composer = composer,
       _editor = editor {
    _composer.addListener(_onComposerChange);
    _document.addListener(_onDocumentChange);
  }

  final MutableDocument _document;
  final MutableDocumentComposer _composer;
  final Editor _editor;

  MutableDocument get document => _document;
  MutableDocumentComposer get composer => _composer;

  /// The current mention being composed, or null if no mention is being typed
  ComposingMention? _composingMention;
  ComposingMention? get composingMention => _composingMention;

  @override
  void dispose() {
    _composer.removeListener(_onComposerChange);
    _document.removeListener(_onDocumentChange);
    super.dispose();
  }

  void _onComposerChange() {
    _checkForMentionTrigger();
  }

  void _onDocumentChange(DocumentChangeLog changeLog) {
    _checkForMentionTrigger();
  }

  void _checkForMentionTrigger() {
    final selection = _composer.selection;
    if (selection == null || !selection.isCollapsed) {
      _clearComposingMention();
      return;
    }

    final node = _document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) {
      _clearComposingMention();
      return;
    }

    final textPosition = selection.extent.nodePosition;
    if (textPosition is! TextNodePosition) {
      _clearComposingMention();
      return;
    }

    final text = node.text.toPlainText();
    final caretOffset = textPosition.offset;

    // Look backwards from the caret to find a mention trigger
    final mentionInfo = _findMentionAtPosition(text, caretOffset);

    if (mentionInfo != null) {
      _setComposingMention(mentionInfo);
    } else {
      _clearComposingMention();
    }
  }

  ComposingMention? _findMentionAtPosition(String text, int caretOffset) {
    final selection = _composer.selection;
    if (selection == null) return null;

    final node = _document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) return null;

    // Look backwards from the caret position to find "@"
    for (int i = caretOffset - 1; i >= 0; i--) {
      final char = text[i];

      if (char == '@') {
        // Check if this @ is part of a committed mention
        final attributionsAtPosition = node.text.getAttributionSpansInRange(
          attributionFilter: (attribution) => attribution is CommittedEditorMentionAttribution,
          range: SpanRange(i, i),
        );

        // If this @ is part of a committed mention, skip it
        if (attributionsAtPosition.isNotEmpty) {
          return null;
        }

        // Only trigger mention if @ is at start of line or preceded by a space
        // This prevents mentions from triggering in email addresses
        if (i > 0 && text[i - 1] != ' ') {
          return null;
        }

        // Found the trigger, extract the text after it
        final startOffset = i;
        final endOffset = caretOffset;
        final mentionText = text.substring(startOffset + 1, endOffset);

        // Check if this is a valid mention (no newlines)
        if (mentionText.contains('\n')) {
          return null;
        }

        return ComposingMention(
          triggerOffset: startOffset,
          text: mentionText,
        );
      }

      // Stop if we hit a newline or tab (not a valid mention)
      // Allow single spaces to support multi-word agent names
      if (char == '\n' || char == '\t') {
        break;
      }
    }

    return null;
  }

  void _setComposingMention(ComposingMention mention) {
    if (_composingMention != mention) {
      _composingMention = mention;
      notifyListeners();
    }
  }

  void _clearComposingMention() {
    if (_composingMention != null) {
      _composingMention = null;
      notifyListeners();
    }
  }

  /// Completes the current mention by replacing the composing text with the selected agent
  /// Displays name in the editor, but serializes to [Name](#@{priorityAgentId}] in markdown
  void completeMention({
    required String priorityAgentId,
    required String username,
  }) {
    final mention = _composingMention;
    if (mention == null) return;

    final selection = _composer.selection;
    if (selection == null || !selection.isCollapsed) return;

    final node = _document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) return;

    // Replace the "@text" with "username " (with trailing space)
    final replaceFromOffset = mention.triggerOffset;
    final replaceToOffset = mention.triggerOffset + 1 + mention.text.length;

    final attribution = CommittedEditorMentionAttribution(
      priorityAgentId: priorityAgentId,
      username: username,
    );
    // Display as username in the editor (will convert to [Name](#@ID) when serializing)
    final replacementText = username;

    // Copy the original text and modify it (methods return new instances)
    var newText = node.text.copy();

    // Remove the "@mentionText" part
    newText = newText.removeRegion(
      startOffset: replaceFromOffset,
      endOffset: replaceToOffset,
    );

    // Insert the username with attribution
    final mentionWithAttribution = AttributedText(replacementText);
    mentionWithAttribution.addAttribution(
      attribution,
      SpanRange(0, replacementText.length - 1),
    );

    newText = newText.insert(
      textToInsert: mentionWithAttribution,
      startOffset: replaceFromOffset,
    );

    // Insert a space after the mention
    newText = newText.insertString(
      textToInsert: ' ',
      startOffset: replaceFromOffset + replacementText.length,
    );

    // Replace the node and update selection through editor's command pipeline
    _editor.execute([
      ReplaceNodeRequest(
        existingNodeId: node.id,
        newNode: ParagraphNode(
          id: node.id,
          text: newText,
          metadata: node.metadata,
        ),
      ),
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(
              offset: replaceFromOffset + replacementText.length + 1,
            ),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);

    // Clear composing state to hide popover
    _clearComposingMention();
  }

  /// Cancels the current mention composition
  void cancelMention() {
    _clearComposingMention();
  }
}

/// Information about a mention that's currently being composed
class ComposingMention {
  const ComposingMention({
    required this.triggerOffset,
    required this.text,
  });

  /// The offset in the text where the "@" trigger appears
  final int triggerOffset;

  /// The text that has been typed after the "@" trigger
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ComposingMention &&
          triggerOffset == other.triggerOffset &&
          text == other.text);

  @override
  int get hashCode => Object.hash(triggerOffset, text);

  @override
  String toString() => 'ComposingMention(triggerOffset: $triggerOffset, text: "$text")';
}