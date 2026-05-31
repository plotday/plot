import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

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

  /// Optional list of contact/user UUID strings displayed as avatar circles.
  final List<String>? avatarSlot;

  /// Called when the pill body is tapped.
  final VoidCallback onTap;

  /// Called when the avatar slot is tapped. Must be non-null when [avatarSlot]
  /// is non-null.
  final VoidCallback? onAvatarsTap;

  const TopBarPill({
    required this.id,
    required this.label,
    this.avatarSlot,
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

// ---------------------------------------------------------------------------
// Pill row (PillRowState)
// ---------------------------------------------------------------------------

class _PillRow extends StatelessWidget {
  final PillRowState state;

  const _PillRow({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (final pill in state.pills) _Pill(pill: pill, isActive: pill.id == state.activeId),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final TopBarPill pill;
  final bool isActive;

  const _Pill({required this.pill, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final activeBackground = colors.primary;
    final activeForeground = colors.primaryForeground;
    final inactiveForeground = colors.mutedForeground;

    final backgroundColor = isActive ? activeBackground : null;
    final foregroundColor = isActive ? activeForeground : inactiveForeground;

    return KeyedSubtree(
      key: Key('pill-${pill.id}'),
      child: GestureDetector(
        onTap: pill.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pill.label,
                style: context.theme.typography.sm.copyWith(
                  color: foregroundColor,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (pill.avatarSlot != null && pill.avatarSlot!.isNotEmpty) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: pill.onAvatarsTap,
                  child: _AvatarPlaceholderRow(ids: pill.avatarSlot!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder avatar row: a small circle per UUID.
/// Task 12 will wire in the real avatar widget.
class _AvatarPlaceholderRow extends StatelessWidget {
  final List<String> ids;

  const _AvatarPlaceholderRow({required this.ids});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final _ in ids)
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: context.theme.colors.mutedForeground.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
          ),
      ],
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
    final accent = ctx.theme.colors.primary;
    final muted = ctx.theme.colors.mutedForeground;

    return Container(
      padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(color: accent.withValues(alpha: 0.35)),
        ),
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
