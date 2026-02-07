import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:super_editor/super_editor.dart';
import 'package:follow_the_leader/follow_the_leader.dart';

import 'icon.dart';

/// A small floating toolbar that shows a link icon button near the selection.
/// Uses SuperEditorPopover + Follower pattern (same as EditorMentionPopover).
class EditorLinkToolbar extends StatelessWidget {
  const EditorLinkToolbar({
    super.key,
    required this.editorFocusNode,
    required this.leaderLink,
    required this.showAbove,
    required this.onLinkTapped,
    required this.hasExistingLink,
  });

  final FocusNode editorFocusNode;
  final LeaderLink leaderLink;
  final bool showAbove;
  final VoidCallback onLinkTapped;
  final bool hasExistingLink;

  @override
  Widget build(BuildContext context) {
    return SuperEditorPopover(
      popoverFocusNode: FocusNode(),
      editorFocusNode: editorFocusNode,
      child: Follower.withOffset(
        link: leaderLink,
        leaderAnchor: Alignment.topLeft,
        followerAnchor:
            showAbove ? Alignment.bottomLeft : Alignment.topLeft,
        offset: const Offset(0, 0),
        showWhenUnlinked: false,
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = context.theme;

    return GestureDetector(
      onTap: onLinkTapped,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colors.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.colors.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0x00000000).withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          PlotIcon.link,
          size: 14,
          color: hasExistingLink
              ? theme.colors.primary
              : theme.colors.mutedForeground,
        ),
      ),
    );
  }
}
