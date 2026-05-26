import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/emoji.dart';
import 'package:plot/widget/reaction_picker.dart';

/// Renders the row of emoji-reaction chips on a [Note] (or [Thread]).
///
/// Each existing reaction renders as a tappable chip showing the emoji and
/// a count of actors. Chips where the current user has reacted are
/// highlighted. A trailing `+` button opens the [ReactionPicker] for adding
/// a new reaction.
///
/// The widget itself is stateless — toggling and adding routes through the
/// supplied [onToggle] callback which the parent wires to a Bloc/Command.
class ReactionRow extends StatelessWidget {
  const ReactionRow({
    required this.reactions,
    required this.selfActorId,
    required this.onToggle,
    this.allowed,
    super.key,
  });

  /// Current reactions: `{ <emoji>: [actorId, ...] }`. May be empty.
  final Reactions reactions;

  /// The current viewer's actor id, used to detect "did I react?".
  final ActorId selfActorId;

  /// Called when the user taps a chip or picks an emoji from the picker.
  /// The caller flips the user's membership in that emoji's actor list and
  /// schedules a sync push.
  final void Function(Reaction emoji) onToggle;

  /// Optional connector-capability filter applied to the picker.
  final Set<Reaction>? allowed;

  @override
  Widget build(BuildContext context) {
    final entries = reactions.entries
        .where((e) => e.value.isNotEmpty)
        .toList(growable: false);

    if (entries.isEmpty) {
      // Just the add-reaction button (compact).
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: _AddReactionButton(
          onPick: (e) => onToggle(e),
          allowed: allowed,
        ),
      );
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final entry in entries)
          _ReactionChip(
            emoji: entry.key,
            count: entry.value.length,
            mine: _includesSelf(entry.value, selfActorId),
            onTap: () => onToggle(entry.key),
          ),
        _AddReactionButton(
          onPick: (e) => onToggle(e),
          allowed: allowed,
        ),
      ],
    );
  }

  static bool _includesSelf(List<ActorId> actors, ActorId self) {
    final canonical = Actor.canonicalId(self);
    return actors.any((id) => Actor.canonicalId(id) == canonical);
  }
}

class _ReactionChip extends StatefulWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });

  final Reaction emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final colour = context.colour;
    final accent = colour.accent;
    final mine = widget.mine;
    final border = mine ? accent.withValues(alpha: 0.6) : colour.border;
    final bg = mine
        ? accent.withValues(alpha: 0.12)
        : (_hovered
            ? colour.muted.withValues(alpha: 0.5)
            : colour.muted.withValues(alpha: 0.25));
    final fg = mine ? accent : colour.foreground;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              EmojiText(widget.emoji, size: 14),
              const SizedBox(width: 4),
              Text(
                widget.count.toString(),
                style: theme.typography.xs.copyWith(
                  color: fg,
                  fontWeight: mine ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddReactionButton extends StatefulWidget {
  const _AddReactionButton({required this.onPick, this.allowed});

  final void Function(Reaction emoji) onPick;
  final Set<Reaction>? allowed;

  @override
  State<_AddReactionButton> createState() => _AddReactionButtonState();
}

class _AddReactionButtonState extends State<_AddReactionButton> {
  bool _hovered = false;
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      final picked = await ReactionPicker.pick(
        context,
        allowed: widget.allowed,
      );
      if (picked != null) widget.onPick(picked);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colour = context.colour;
    final bg = _hovered
        ? colour.muted.withValues(alpha: 0.5)
        : colour.muted.withValues(alpha: 0.25);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _open,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: colour.border, width: 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '+',
            style: context.theme.typography.sm.copyWith(
              color: colour.muted,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
