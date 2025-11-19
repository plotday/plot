import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:super_editor/super_editor.dart';
import 'package:follow_the_leader/follow_the_leader.dart';

import 'package:plot/api/twist_api.dart';

/// A popover that displays a list of twists for editor mentions.
///
/// This widget appears when a user types "@" and shows a filtered list
/// of twists that can be selected for mentioning.
class EditorMentionPopover extends StatefulWidget {
  const EditorMentionPopover({
    super.key,
    required this.editorFocusNode,
    required this.leaderLink,
    required this.twists,
    required this.composingText,
    required this.onAgentSelected,
    required this.onCancelRequested,
    this.showAbove = false,
  });

  /// The focus node of the editor
  final FocusNode editorFocusNode;

  /// Link to the widget that this popover follows
  final LeaderLink leaderLink;

  /// The list of all available twists
  final List<PriorityTwist> twists;

  /// The current text being composed (after "@")
  final String composingText;

  /// Whether to show the popover above the trigger (true) or below (false)
  final bool showAbove;

  /// Callback when an twist is selected
  final void Function(PriorityTwist twist) onAgentSelected;

  /// Callback when the user cancels the mention (e.g., presses ESC)
  final VoidCallback onCancelRequested;

  @override
  State<EditorMentionPopover> createState() => _EditorMentionPopoverState();
}

class _EditorMentionPopoverState extends State<EditorMentionPopover> {
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;

  List<PriorityTwist> _filteredAgents = [];
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _scrollController = ScrollController();
    _updateFilteredAgents();

    // Request focus on the next frame to ensure the widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(EditorMentionPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.composingText != widget.composingText ||
        oldWidget.twists != widget.twists) {
      _updateFilteredAgents();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateFilteredAgents() {
    setState(() {
      _filteredAgents = widget.twists
          .where(
            (twist) => twist.name.toLowerCase().contains(
              widget.composingText.toLowerCase(),
            ),
          )
          .toList();

      // Reset selection if it's out of bounds
      if (_selectedIndex >= _filteredAgents.length) {
        _selectedIndex = 0;
      }
    });
  }

  void _selectCurrent() {
    if (_filteredAgents.isNotEmpty) {
      widget.onAgentSelected(_filteredAgents[_selectedIndex]);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (_filteredAgents.isEmpty) {
          return KeyEventResult.handled;
        }
        setState(() {
          _selectedIndex =
              (_selectedIndex - 1 + _filteredAgents.length) %
              _filteredAgents.length;
        });
        _scrollToSelected();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        if (_filteredAgents.isEmpty) {
          return KeyEventResult.handled;
        }
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % _filteredAgents.length;
        });
        _scrollToSelected();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.tab:
        _selectCurrent();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.escape:
        widget.onCancelRequested();
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;

    // Use ensureVisible which handles dynamic item heights
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      // Estimate scroll position (items are approximately 41-45px each)
      const estimatedItemHeight = 44.0;
      final estimatedOffset = _selectedIndex * estimatedItemHeight;
      final viewportHeight = _scrollController.position.viewportDimension;
      final currentScroll = _scrollController.offset;

      // Only scroll if item is likely outside visible area
      if (estimatedOffset < currentScroll) {
        _scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      } else if (estimatedOffset + estimatedItemHeight >
          currentScroll + viewportHeight) {
        _scrollController.animateTo(
          (estimatedOffset + estimatedItemHeight - viewportHeight).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SuperEditorPopover(
      popoverFocusNode: _focusNode,
      editorFocusNode: widget.editorFocusNode,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        onTap: () {
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        },
        child: Builder(
          builder: (context) {
            return Follower.withOffset(
              link: widget.leaderLink,
              leaderAnchor: Alignment.topLeft,
              followerAnchor: widget.showAbove
                  ? Alignment.bottomLeft
                  : Alignment.topLeft,
              offset: const Offset(0, 0),
              showWhenUnlinked: false,
              child: _buildPopoverContent(context),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPopoverContent(BuildContext context) {
    final theme = context.theme;

    return Container(
      constraints: const BoxConstraints(maxWidth: 250, maxHeight: 200),
      decoration: BoxDecoration(
        color: theme.colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colors.border, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0x00000000).withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildUserList(context),
      ),
    );
  }

  Widget _buildUserList(BuildContext context) {
    return FTileGroup.builder(
      scrollController: _scrollController,
      divider: FItemDivider.none,
      count: _filteredAgents.length,
      tileBuilder: (context, index) {
        final twist = _filteredAgents[index];
        final isSelected = index == _selectedIndex;
        return FTile(
          title: Text(twist.name),
          selected: isSelected,
          onPress: () => widget.onAgentSelected(twist),
          // ignore: unused_result
          style: context.theme.tileStyle.copyWith(
            decoration: FWidgetStateMap({
              WidgetState.any: BoxDecoration(
                color: isSelected
                    ? context.theme.colors.background.withAlpha(172)
                    : context.theme.colors.background,
              ),
            }),
          ),
        );
      },
    );
  }
}
