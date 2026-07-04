import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart';

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

/// Takeover chrome shown while composing a forward.
class ForwardingState extends TopBarState {
  final String quotePreview;

  const ForwardingState({required this.quotePreview});
}

// ---------------------------------------------------------------------------
// TopBarPill value type
// ---------------------------------------------------------------------------

/// A single pill in the [PillRowState] row.
class TopBarPill {
  final String id;
  final String label;

  /// Icon drawn before the label (e.g. reply / reply-all). Null = no icon.
  final IconData? leadingIcon;

  /// Recipient count rendered in a small pill just before [editIcon].
  /// Only shown when [editIcon] is non-null. Null = no count shown.
  final int? recipientCount;

  /// Trailing edit-affordance icon (pencil to edit recipients, user-plus to
  /// add). Null = no edit affordance.
  final IconData? editIcon;

  /// Tooltip shown over the [editIcon]/[recipientCount] affordance.
  final String? editTooltip;

  /// When true, the pill's label may shrink and ellipsize to fit the available
  /// width instead of pushing the row into overflow. Use for pills with a
  /// variable-length label (e.g. "Reply to {name}"); fixed-label pills should
  /// keep their natural width.
  final bool flexible;

  /// Called when the pill body (leading icon + label) is tapped.
  final VoidCallback onTap;

  /// Called when the [recipientCount]/[editIcon] affordance is tapped (opens
  /// the recipient editor). When non-null the affordance brightens on hover.
  final VoidCallback? onEdit;

  const TopBarPill({
    required this.id,
    required this.label,
    this.leadingIcon,
    this.recipientCount,
    this.editIcon,
    this.editTooltip,
    this.flexible = false,
    required this.onTap,
    this.onEdit,
  }) : assert(
         recipientCount == null || editIcon != null,
         'recipientCount is only rendered when editIcon is non-null',
       );
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

  /// Whether the editor below has rounded top corners (bottom-positioned
  /// EditableArea). When true the bar's top corners are clipped to match so
  /// its solid background doesn't paint square corners over the rounded
  /// editor border. False in bodyOnly / flushToBottom (square-topped) modes.
  final bool roundTop;

  final VoidCallback onClearReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onClearForward;

  const NoteEditorTopBar({
    super.key,
    required this.state,
    required this.roundTop,
    required this.onClearReply,
    required this.onCancelEdit,
    required this.onClearForward,
  });

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      final PillRowState s => _PillRow(state: s, roundTop: roundTop),
      final ReplyingState s => _TakeoverBar(
        icon: FontAwesomeIcons.reply,
        label: 'Replying',
        quotePreview: s.quotePreview,
        onClear: onClearReply,
        roundTop: roundTop,
        context: context,
      ),
      final EditingState s => _TakeoverBar(
        icon: FontAwesomeIcons.penToSquare,
        label: 'Editing',
        quotePreview: s.quotePreview,
        onClear: onCancelEdit,
        roundTop: roundTop,
        context: context,
      ),
      final ForwardingState s => _TakeoverBar(
        icon: FontAwesomeIcons.share,
        label: 'Forwarding',
        quotePreview: s.quotePreview,
        onClear: onClearForward,
        roundTop: roundTop,
        context: context,
      ),
    };
  }
}

/// Clips [child] so its top-left/top-right corners match the editor's rounded
/// border. Used by the pill row and takeover bar — both paint a full-width
/// solid background that would otherwise square off the editor's top corners.
/// A no-op (returns [child] unchanged) when [round] is false.
Widget _roundTopCorners({required bool round, required Widget child}) {
  if (!round) return child;
  return ClipRRect(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(borderRadiusMd),
    ),
    child: child,
  );
}

// Shared height for the pill row and takeover bar so the chrome doesn't shift
// when the state switches between them.
const double _topBarHeight = 32;

// ---------------------------------------------------------------------------
// Pill row (PillRowState)
// ---------------------------------------------------------------------------

class _PillRow extends StatelessWidget {
  final PillRowState state;
  final bool roundTop;

  const _PillRow({required this.state, required this.roundTop});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return _roundTopCorners(
      round: roundTop,
      child: Container(
        height: _topBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: context.colour.sectionHeaderBackground,
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: Row(
          children: [
            for (final pill in state.pills)
              if (pill.flexible)
                Flexible(
                  child: _Pill(pill: pill, isActive: pill.id == state.activeId),
                )
              else
                _Pill(pill: pill, isActive: pill.id == state.activeId),
          ],
        ),
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

  Widget _label(BuildContext context, Color foregroundColor) {
    return Text(
      widget.pill.label,
      maxLines: 1,
      overflow: widget.pill.flexible
          ? TextOverflow.ellipsis
          : TextOverflow.clip,
      style: context.theme.typography.sm.copyWith(
        color: foregroundColor,
        fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

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
                if (widget.pill.leadingIcon != null) ...[
                  Icon(
                    widget.pill.leadingIcon,
                    size: 11,
                    color: foregroundColor,
                  ),
                  const SizedBox(width: 5),
                ],
                // A flexible pill (variable-length label) may shrink: wrap the
                // label so it ellipsizes within the space the parent Row grants
                // it instead of overflowing. Fixed-label pills keep their
                // natural width (and must not use Flexible — the surrounding
                // Row gives them unbounded width).
                if (widget.pill.flexible)
                  Flexible(child: _label(context, foregroundColor))
                else
                  _label(context, foregroundColor),
                if (widget.pill.editIcon != null) ...[
                  const SizedBox(width: 6),
                  _EditAffordance(
                    count: widget.pill.recipientCount,
                    icon: widget.pill.editIcon!,
                    tooltip: widget.pill.editTooltip,
                    onTap: widget.pill.onEdit,
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

/// The recipient count pill + edit icon shown on the reply-all / reply pills.
/// Its own tap target (so it fires [onTap] instead of the pill's body tap) and
/// brightens on hover. Wrapped in an [FTooltip] when [tooltip] is set.
class _EditAffordance extends StatefulWidget {
  final int? count;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  const _EditAffordance({
    required this.count,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_EditAffordance> createState() => _EditAffordanceState();
}

class _EditAffordanceState extends State<_EditAffordance> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final color = _hovering ? colors.foreground : colors.mutedForeground;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.count != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: colors.mutedForeground.withValues(
                alpha: _hovering ? 0.18 : 0.12,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${widget.count}',
              style: context.theme.typography.xs.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Icon(widget.icon, size: 11, color: color),
      ],
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: content,
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip == null) return hoverable;
    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: hoverable,
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
  final bool roundTop;
  // ignore: unused_field
  final BuildContext context;

  const _TakeoverBar({
    required this.icon,
    required this.label,
    required this.quotePreview,
    required this.onClear,
    required this.roundTop,
    required this.context,
  });

  @override
  Widget build(BuildContext ctx) {
    final colors = ctx.theme.colors;
    final accent = colors.primary;
    final muted = colors.mutedForeground;

    final bar = Container(
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

    return _roundTopCorners(round: roundTop, child: bar);
  }
}
