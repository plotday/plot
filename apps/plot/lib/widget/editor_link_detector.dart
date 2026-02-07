import 'package:flutter/widgets.dart';
import 'package:super_editor/super_editor.dart';

/// Detects when the link toolbar should be shown based on composer selection
/// and document state. Shows toolbar when text is selected or cursor is inside
/// a LinkAttribution.
class EditorLinkDetector extends ChangeNotifier {
  EditorLinkDetector({
    required MutableDocument document,
    required MutableDocumentComposer composer,
  }) : _document = document,
       _composer = composer {
    _composer.selectionNotifier.addListener(_onComposerChange);
    _document.addListener(_onDocumentChange);
  }

  final MutableDocument _document;
  final MutableDocumentComposer _composer;

  bool _shouldShowToolbar = false;
  LinkAttribution? _existingLink;
  SpanRange? _linkSpanRange;
  String? _linkNodeId;
  bool _hasSelection = false;

  /// Whether the link toolbar should be visible
  bool get shouldShowToolbar => _shouldShowToolbar;

  /// The existing link attribution if cursor is inside one, null otherwise
  LinkAttribution? get existingLink => _existingLink;

  /// The span range of the existing link attribution within the node
  SpanRange? get linkSpanRange => _linkSpanRange;

  /// The node ID containing the existing link
  String? get linkNodeId => _linkNodeId;

  /// Whether there is a non-collapsed text selection
  bool get hasSelection => _hasSelection;

  @override
  void dispose() {
    _composer.selectionNotifier.removeListener(_onComposerChange);
    _document.removeListener(_onDocumentChange);
    super.dispose();
  }

  void _onComposerChange() {
    _detectLinkState();
  }

  void _onDocumentChange(DocumentChangeLog changeLog) {
    _detectLinkState();
  }

  void _detectLinkState() {
    final selection = _composer.selection;

    if (selection == null) {
      _updateState(
        shouldShow: false,
        link: null,
        spanRange: null,
        nodeId: null,
        hasSel: false,
      );
      return;
    }

    final isCollapsed = selection.isCollapsed;
    final hasNonCollapsedSelection = !isCollapsed;

    // Check if cursor is inside a link (collapsed selection only)
    LinkAttribution? foundLink;
    SpanRange? foundSpanRange;
    String? foundNodeId;

    if (isCollapsed) {
      final node = _document.getNodeById(selection.extent.nodeId);
      if (node is TextNode) {
        final nodePosition = selection.extent.nodePosition;
        if (nodePosition is TextNodePosition) {
          final offset = nodePosition.offset;
          if (offset > 0 && node.text.length > 0) {
            // Check at offset-1 (the character before the cursor)
            final checkOffset = (offset - 1).clamp(0, node.text.length - 1);
            final spans = node.text.getAttributionSpansInRange(
              attributionFilter: (a) => a is LinkAttribution,
              range: SpanRange(checkOffset, checkOffset),
            );
            if (spans.isNotEmpty) {
              final span = spans.first;
              foundLink = span.attribution as LinkAttribution;
              foundSpanRange = SpanRange(span.start, span.end);
              foundNodeId = node.id;
            }
          }
        }
      }
    }

    // Also check for link at selection extent when non-collapsed
    if (hasNonCollapsedSelection) {
      final node = _document.getNodeById(selection.extent.nodeId);
      if (node is TextNode) {
        final nodePosition = selection.extent.nodePosition;
        if (nodePosition is TextNodePosition) {
          final offset = nodePosition.offset;
          if (offset > 0 && node.text.length > 0) {
            final checkOffset = (offset - 1).clamp(0, node.text.length - 1);
            final spans = node.text.getAttributionSpansInRange(
              attributionFilter: (a) => a is LinkAttribution,
              range: SpanRange(checkOffset, checkOffset),
            );
            if (spans.isNotEmpty) {
              final span = spans.first;
              foundLink = span.attribution as LinkAttribution;
              foundSpanRange = SpanRange(span.start, span.end);
              foundNodeId = node.id;
            }
          }
        }
      }
    }

    final shouldShow = hasNonCollapsedSelection || foundLink != null;

    _updateState(
      shouldShow: shouldShow,
      link: foundLink,
      spanRange: foundSpanRange,
      nodeId: foundNodeId,
      hasSel: hasNonCollapsedSelection,
    );
  }

  void _updateState({
    required bool shouldShow,
    required LinkAttribution? link,
    required SpanRange? spanRange,
    required String? nodeId,
    required bool hasSel,
  }) {
    if (_shouldShowToolbar != shouldShow ||
        _existingLink != link ||
        _linkSpanRange != spanRange ||
        _linkNodeId != nodeId ||
        _hasSelection != hasSel) {
      _shouldShowToolbar = shouldShow;
      _existingLink = link;
      _linkSpanRange = spanRange;
      _linkNodeId = nodeId;
      _hasSelection = hasSel;
      notifyListeners();
    }
  }
}
