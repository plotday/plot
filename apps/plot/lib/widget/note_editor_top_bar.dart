import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/avatar.dart';

// ---------------------------------------------------------------------------
// State hierarchy
// ---------------------------------------------------------------------------

/// Sealed base class for the three modes the top bar can be in.
sealed class TopBarState {
  const TopBarState();
}

/// The pill row — shows note-type selectors (reply, task, private note, etc.).
class PillRowState extends TopBarState {
  final List<TopBarPill> pills;
  final String? activeId;

  const PillRowState({required this.pills, this.activeId});
}

/// Takeover chrome shown while composing a reply.
class ReplyingState extends TopBarState {
  final String quotePreview;

  const ReplyingState({required this.quotePreview});
}

/// Takeover chrome shown while editing an existing note.
class EditingState extends TopBarState {
  final String quotePreview;

  const EditingState({required this.quotePreview});
}

// ---------------------------------------------------------------------------
// TopBarPill value type
// ---------------------------------------------------------------------------

/// A single pill in the [PillRowState] row.
class TopBarPill {
  final String id;
  final String label;

  /// Resolved actors to draw in the pill's avatar cluster, in display order.
  /// Null/empty = no cluster. Groups and any not-yet-cached contacts aren't
  /// drawn individually — they're folded into the "+N" overflow via
  /// [avatarTotalCount].
  final List<Actor>? avatarActors;

  /// Total audience size (non-self contacts + groups) the cluster represents,
  /// driving the "+N" overflow badge. Defaults to [avatarActors] length.
  final int? avatarTotalCount;

  /// Called when the pill body is tapped.
  final VoidCallback onTap;

  /// Called when the avatar cluster is tapped (opens the recipient picker).
  /// When non-null the cluster brightens on hover to signal the affordance.
  final VoidCallback? onAvatarsTap;

  const TopBarPill({
    required this.id,
    required this.label,
    this.avatarActors,
    this.avatarTotalCount,
    required this.onTap,
    this.onAvatarsTap,
  });
}

// ---------------------------------------------------------------------------
// NoteEditorTopBar
// ---------------------------------------------------------------------------

/// Pure-presentation widget that owns the top region of the note editor.
///
/// The parent computes a [TopBarState] from thread + draft context and passes
/// it in. Callbacks bubble up: [onClearReply] is called to clear the reply-to,
/// [onCancelEdit] is called to cancel note editing.
///
/// No Bloc reads, no DB calls — just renders what it's given.
class NoteEditorTopBar extends StatelessWidget {
  final TopBarState state;
  final VoidCallback onClearReply;
  final VoidCallback onCancelEdit;

  const NoteEditorTopBar({
    super.key,
    required this.state,
    required this.onClearReply,
    required this.onCancelEdit,
  });

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      final PillRowState s => _PillRow(state: s),
      final ReplyingState s => _TakeoverBar(
        icon: FontAwesomeIcons.reply,
        label: 'Replying',
        quotePreview: s.quotePreview,
        onClear: onClearReply,
        context: context,
      ),
      final EditingState s => _TakeoverBar(
        icon: FontAwesomeIcons.penToSquare,
        label: 'Editing',
        quotePreview: s.quotePreview,
        onClear: onCancelEdit,
        context: context,
      ),
    };
  }
}

// Shared height for the pill row and takeover bar so the chrome doesn't shift
// when the state switches between them.
const double _topBarHeight = 32;

// ---------------------------------------------------------------------------
// Pill row (PillRowState)
// ---------------------------------------------------------------------------

class _PillRow extends StatelessWidget {
  final PillRowState state;

  const _PillRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Container(
      height: _topBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: colors.mutedForeground.withValues(alpha: 0.05),
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          for (final pill in state.pills)
            _Pill(pill: pill, isActive: pill.id == state.activeId),
        ],
      ),
    );
  }
}

class _Pill extends StatefulWidget {
  final TopBarPill pill;
  final bool isActive;

  const _Pill({required this.pill, required this.isActive});

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final activeForeground = colors.primary;
    final inactiveForeground = _hovering
        ? colors.foreground
        : colors.mutedForeground;
    final foregroundColor = widget.isActive
        ? activeForeground
        : inactiveForeground;

    return KeyedSubtree(
      key: Key('pill-${widget.pill.id}'),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.pill.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.pill.label,
                  style: context.theme.typography.sm.copyWith(
                    color: foregroundColor,
                    fontWeight: widget.isActive
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (widget.pill.avatarActors != null &&
                    widget.pill.avatarActors!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: widget.pill.onAvatarsTap,
                    child: AvatarGroup(
                      actors: widget.pill.avatarActors!,
                      totalCount: widget.pill.avatarTotalCount,
                      maxVisible: 3,
                      size: 16,
                      clickable: widget.pill.onAvatarsTap != null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Takeover bar (ReplyingState / EditingState)
// ---------------------------------------------------------------------------

class _TakeoverBar extends StatelessWidget {
  final IconData icon;
  final String label;
  final String quotePreview;
  final VoidCallback onClear;
  // ignore: unused_field
  final BuildContext context;

  const _TakeoverBar({
    required this.icon,
    required this.label,
    required this.quotePreview,
    required this.onClear,
    required this.context,
  });

  @override
  Widget build(BuildContext ctx) {
    final colors = ctx.theme.colors;
    final accent = colors.primary;
    final muted = colors.mutedForeground;

    return Container(
      height: _topBarHeight,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: ctx.theme.typography.xs.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (quotePreview.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                quotePreview,
                style: ctx.theme.typography.xs.copyWith(color: muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          GestureDetector(
            key: const Key('top-bar-clear'),
            onTap: onClear,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(FontAwesomeIcons.xmark, size: 12, color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
