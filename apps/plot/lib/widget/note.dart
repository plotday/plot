import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/recipient_change_line.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/util/platform.dart';

class _NoteReplyReference extends StatefulWidget {
  const _NoteReplyReference({required this.reNoteId});

  final NoteId reNoteId;

  @override
  State<_NoteReplyReference> createState() => _NoteReplyReferenceState();
}

class _NoteReplyReferenceState extends State<_NoteReplyReference> {
  bool _isHovered = false;
  late final Future<Note?> _noteFuture;

  @override
  void initState() {
    super.initState();
    _noteFuture = Note.get(widget.reNoteId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Note?>(
      future: _noteFuture,
      builder: (context, snapshot) {
        final reNote = snapshot.data;
        final String preview;
        if (snapshot.connectionState != ConnectionState.done) {
          preview = '...';
        } else if (reNote == null) {
          preview = '[deleted]';
        } else {
          final raw = reNote.content ?? '';
          preview = raw.split('\n').first;
        }

        return GestureDetector(
          onTap: () =>
              context.read<ThreadBloc>().setThreadFilter(widget.reNoteId),
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: Container(
              padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: _isHovered
                        ? context.colour.foreground
                        : context.colour.muted,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                preview,
                style: context.theme.typography.xs.copyWith(
                  color: _isHovered
                      ? context.colour.foreground
                      : context.colour.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }
}

class NoteWidget extends StatefulWidget {
  const NoteWidget({
    required this.note,
    this.selected = false,
    this.dimmed = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.showAuthor = true,
    this.searchHighlight,
    this.initiallyExpanded = false,
    super.key,
  });

  final Note note;
  final bool selected;
  final bool dimmed;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;
  final bool showAuthor;
  final String? searchHighlight;

  /// Whether the note's content should start fully expanded (untruncated)
  /// instead of height-truncated with the "View all" fade. Set by ThreadPage
  /// for a lone note or for unread notes. See `util/note_initial_view.dart`.
  final bool initiallyExpanded;

  @override
  State<NoteWidget> createState() => _NoteWidgetState();
}

class _NoteWidgetState extends State<NoteWidget> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(NoteWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChange);
      widget.focusNode?.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final noteContent = widget.note.content ?? '';
    final noteLinks = widget.note.actions ?? [];
    final activityBloc = context.read<ThreadBloc>();

    final hasFocus = widget.focusNode?.hasFocus ?? false;

    final threadState = activityBloc.state;
    // Per-message recipient-change line for message-mode threads. Compare this
    // note's audience to the chronologically-previous note's. Order-independent
    // (sorts by sourceCreatedAt) so it doesn't depend on the list's order.
    final sharingModel = Thread.resolveSharingModel(threadState.links);
    String? changeLabel;
    if (sharingModel == SharingModel.message) {
      final ordered = [...threadState.notes]
        ..sort((a, b) => a.sourceCreatedAt.compareTo(b.sourceCreatedAt));
      final idx = ordered.indexWhere((n) => n.id == widget.note.id);
      final prev = idx > 0 ? ordered[idx - 1] : null;
      if (prev != null) {
        Set<Uuid> audience(Note n) {
          final access = n.accessContacts;
          if (access != null) {
            return {n.authorId.value, ...access.map((a) => a.value)};
          }
          // Legacy note with no explicit recipients: treat the whole thread
          // roster as the audience so a null note doesn't fabricate a change.
          return {n.authorId.value, ...threadState.thread.contacts};
        }
        changeLabel = Thread.recipientChangeLabel(
          previous: audience(prev),
          current: audience(widget.note),
          viewerContactIds:
              Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet(),
          nameLookup: (id) =>
              Actor.fromCache(ActorId.fromUuid(id))?.nameOrEmail ?? 'Someone',
        );
      }
    }

    final listTile = ListTile(
      padding: const EdgeInsets.only(left: 10, right: 16, top: 8),
      borderRadius: BorderRadius.circular(8),
      bodyBuilder: (context, highlighted) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changeLabel != null) RecipientChangeLine(label: changeLabel),
          if (widget.note.reNoteId != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, bottom: 4),
              child: _NoteReplyReference(reNoteId: widget.note.reNoteId!),
            ),
          if (noteContent.isNotEmpty)
            Padding(
              padding: .symmetric(horizontal: 6),
              child: _TruncatedNoteContent(
                note: widget.note,
                searchHighlight: widget.searchHighlight,
                noteHovered: _hovered,
                initiallyExpanded: widget.initiallyExpanded,
              ),
            ),
          if (noteLinks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: 6,
                right: 6,
                top: 8,
                bottom: 4,
              ),
              child: _NoteActionsLayout(actions: noteLinks, note: widget.note),
            ),
          SizedBox(
            height: 30,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Author/timestamp positioned on the right, overlapping if needed
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Builder(
                    builder: (context) {
                      final mutedXs = context.theme.typography.xs.copyWith(
                        color: context.colour.muted,
                      );
                      final timeAgo = FTooltip(
                        tipBuilder: (context, controller) => Text(
                          widget.note.sourceCreatedAt.toLocal().format(
                            'MMM d, yyyy, h:mm a',
                          ),
                        ),
                        child: Text(
                          widget.note.sourceCreatedAt.toTimeAgo(),
                          style: mutedXs,
                        ),
                      );
                      Widget withPending(Widget child) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PendingSyncIndicator(note: widget.note),
                          child,
                        ],
                      );
                      if (!widget.showAuthor) return withPending(timeAgo);
                      return FutureBuilder<Actor?>(
                        future: widget.note.getAuthor(),
                        builder: (context, snapshot) {
                          final actor = snapshot.data;
                          final authorName = actor == null
                              ? null
                              : (widget.note.authorId.isCurrentUser
                                    ? 'You'
                                    : actor.nameOrEmail);
                          if (authorName == null || authorName.isEmpty) {
                            return withPending(timeAgo);
                          }
                          Widget authorText = Text(authorName, style: mutedXs);
                          if (actor?.email != null &&
                              actor!.email != authorName) {
                            authorText = FTooltip(
                              tipBuilder: (context, controller) =>
                                  Text(actor.email!),
                              child: authorText,
                            );
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _PendingSyncIndicator(note: widget.note),
                              if (actor != null) ...[
                                Avatar(actor: actor, tooltip: false),
                                const SizedBox(width: 4),
                              ],
                              authorText,
                              const SizedBox(width: 4),
                              Text('•', style: mutedXs),
                              const SizedBox(width: 4),
                              timeAgo,
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                // NoteCommands overlays the author row with a solid
                // background and gradient fade so the author/timestamp
                // truncates cleanly rather than bleeding through the
                // icons. Mirrors the ThreadCommands treatment.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(
                      6 -
                          context
                              .theme
                              .buttonStyles
                              .ghost
                              .md
                              .iconContentStyle
                              .padding
                              .resolve(TextDirection.ltr)
                              .left,
                      0,
                    ),
                    child: NoteCommands(
                      note: widget.note,
                      showCommands: _hovered,
                      tileBg: widget.selected
                          ? context.theme.colors.primaryForeground
                          : hasFocus
                          ? Color.alphaBlend(
                              context.theme.plotColors.highlight,
                              context.theme.colors.background,
                            )
                          : context.theme.colors.background,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      selected: widget.selected,
      focusNode: widget.focusNode,
      onHover: widget.onHover,
      reorderableIndex: widget.reorderableIndex,
      longPressCommand: !hasPhysicalKeyboard()
          ? ShowNoteCommands(widget.note, activityBloc: activityBloc)
          : null,
      noHoverHighlight: true,
    );

    Widget result;
    if (hasPhysicalKeyboard()) {
      result = ContextMenu(
        items: (close) => noteCommands(widget.note, activityBloc: activityBloc)
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
                onPress: () {
                  close();
                  context.run(cmd);
                },
              ),
            )
            .toList(),
        child: listTile,
      );
    } else {
      result = listTile;
    }

    if (widget.dimmed) {
      result = Opacity(opacity: 0.4, child: result);
    }
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: result,
    );
  }
}

/// Exposes the height available for a single note's content inside the
/// scrolling list — the panel height minus pinned headers and the
/// composer. Consumed by [_TruncatedNoteContent] to size its truncation
/// cap so a long note fills the visible panel without spilling into a
/// scroll. Falls back to a sensible default when no ancestor provides it.
class NotePanelMetrics extends InheritedWidget {
  const NotePanelMetrics({
    required this.availableHeight,
    required super.child,
    super.key,
  });

  final double availableHeight;

  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NotePanelMetrics>()
      ?.availableHeight;

  @override
  bool updateShouldNotify(NotePanelMetrics oldWidget) =>
      availableHeight != oldWidget.availableHeight;
}

/// Inline note content sized to fill the visible panel. When the
/// rendered Viewer exceeds the available height, the bottom is faded out
/// and a "View all" affordance appears on hover; tapping the fade or the
/// affordance expands the note inline (no separate viewer panel). Once
/// expanded, the note stays expanded — there is no inline collapse.
class _TruncatedNoteContent extends StatefulWidget {
  const _TruncatedNoteContent({
    required this.note,
    required this.noteHovered,
    this.searchHighlight,
    this.initiallyExpanded = false,
  });

  final Note note;
  final String? searchHighlight;

  /// Whether the parent note widget is currently hovered. The "View all"
  /// signifier only renders while this is true; otherwise it stays hidden
  /// so the inline view is uncluttered.
  final bool noteHovered;

  /// Whether the note starts expanded (untruncated) on first build.
  final bool initiallyExpanded;

  /// Fallback cap when no [NotePanelMetrics] ancestor is available
  /// (e.g. previews, tests). Comfortably fits a screenful of prose.
  static const double _fallbackMaxHeight = 600.0;

  /// Approximate per-note chrome the truncation cap subtracts from the
  /// panel's list area: 8px top padding + 30px footer row + breathing.
  /// Slightly conservative so the truncated note stays under the
  /// visible-without-scroll budget instead of nudging into a scroll.
  static const double _noteChrome = 60.0;

  /// Height of the bottom fade gradient overlaid on truncated content.
  static const double fadeHeight = 80.0;

  @override
  State<_TruncatedNoteContent> createState() => _TruncatedNoteContentState();
}

class _TruncatedNoteContentState extends State<_TruncatedNoteContent> {
  bool _overflow = false;
  bool _fadeHovered = false;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  /// Identifies the [_OverflowAwareBox] render object so [_expandInline]
  /// can read its already-measured natural height and predict the layout
  /// delta synchronously, before the rebuild.
  final GlobalKey _measureKey = GlobalKey();

  /// Expand the note inline while keeping the visible content stationary.
  /// In a reverse list the bottom is anchored, so growing a note pushes
  /// the rest of its content visually upward — the user sees the END of
  /// the note where they were reading the start.
  ///
  /// Doing the correction in a post-frame callback paints one frame with
  /// the wrong scroll position (the visible flash). Instead, we ask the
  /// already-laid-out [_OverflowAwareRenderBox] for its measured natural
  /// height, derive the height delta the rebuild will produce, and apply
  /// `pos.correctBy(delta)` _before_ the rebuild. `correctBy` adjusts
  /// pixels without notifying or repainting; the next layout (triggered
  /// by `setState`) validates the new pixels against the new max and
  /// paints a single, correctly-positioned frame.
  void _expandInline() {
    final scrollable = Scrollable.maybeOf(context);
    final pos = scrollable?.position;
    final renderObject = _measureKey.currentContext?.findRenderObject();
    double? delta;
    if (renderObject is _OverflowAwareRenderBox && renderObject.attached) {
      delta = renderObject.naturalHeight - renderObject.size.height;
    }

    if (pos != null &&
        delta != null &&
        delta > 0.5 &&
        pos.axisDirection == AxisDirection.up) {
      // Reverse-vertical scroll: growing an in-viewport item pushes
      // older content upward. Scrolling forward by the same amount
      // cancels the shift. Skip clamping — the next layout will apply
      // the new max and validate.
      pos.correctBy(delta);
    }

    setState(() => _expanded = true);
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.note.content ?? '';
    final viewer = Viewer(
      markdown: content,
      searchHighlight: widget.searchHighlight,
    );

    // Once expanded, render the note's full natural height inline —
    // the parent list handles scrolling. No collapse for now.
    if (_expanded) return viewer;

    final available =
        NotePanelMetrics.maybeOf(context) ??
        _TruncatedNoteContent._fallbackMaxHeight;
    final maxHeight = (available - _TruncatedNoteContent._noteChrome).clamp(
      160.0,
      double.infinity,
    );

    final bg = context.colour.background;
    // The fade gradient is painted by the render layer in
    // [_OverflowAwareBox.paint] so it lands on the same frame as the
    // truncation decision — avoiding the unfaded-then-faded flash that a
    // build-time Flutter widget would produce (build runs before layout,
    // so the widget tree on the first frame doesn't yet know overflow
    // happened).
    final measured = _OverflowAwareBox(
      key: _measureKey,
      maxHeight: maxHeight,
      // Truncate as soon as content exceeds the cap — the goal is to
      // fill the panel, not to render extra inline.
      truncateAt: maxHeight,
      fadeHeight: _TruncatedNoteContent.fadeHeight,
      fadeColor: bg,
      onOverflowChanged: (overflow) {
        if (!mounted || overflow == _overflow) return;
        setState(() => _overflow = overflow);
      },
      child: viewer,
    );

    if (!_overflow) return measured;

    return Stack(
      children: [
        measured,
        // Transparent click target covering the fade region. The visible
        // gradient is painted by [_OverflowAwareBox] itself; this widget
        // is purely a hit zone + hover tracker.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _TruncatedNoteContent.fadeHeight,
          child: MouseRegion(
            onEnter: (_) {
              if (!_fadeHovered) setState(() => _fadeHovered = true);
            },
            onExit: (_) {
              if (_fadeHovered) setState(() => _fadeHovered = false);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _expandInline,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // "View all" signifier — only rendered while the note is hovered,
        // sitting at the bottom of the fade gradient. Muted when the fade
        // itself isn't being hovered, foreground when it is. IgnorePointer
        // so it never intercepts taps; the fade itself is the click target.
        if (widget.noteHovered)
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: IgnorePointer(
              child: Center(child: _ViewAllPill(active: _fadeHovered)),
            ),
          ),
      ],
    );
  }
}

class _ViewAllPill extends StatelessWidget {
  const _ViewAllPill({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? context.theme.colors.foreground
        : context.colour.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.colour.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.upRightAndDownLeftFromCenter,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            'View all',
            style: context.theme.typography.sm.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lays out [child] with unbounded vertical constraints, captures its
/// natural height, and — only when natural > [truncateAt] — clamps its
/// own height to [maxHeight]. Content between [maxHeight] and
/// [truncateAt] renders in full so medium-length notes don't get clipped.
/// When truncated, paints a [fadeHeight]-tall gradient from transparent to
/// [fadeColor] at the bottom — done at the render layer so the fade
/// arrives on the same frame as the truncation, with no build-time flash.
/// Reports whether truncation kicked in via [onOverflowChanged].
class _OverflowAwareBox extends SingleChildRenderObjectWidget {
  const _OverflowAwareBox({
    super.key,
    required this.maxHeight,
    required this.truncateAt,
    required this.fadeHeight,
    required this.fadeColor,
    required this.onOverflowChanged,
    required Widget super.child,
  });

  final double maxHeight;
  final double truncateAt;
  final double fadeHeight;
  final Color fadeColor;
  final ValueChanged<bool> onOverflowChanged;

  @override
  _OverflowAwareRenderBox createRenderObject(BuildContext context) =>
      _OverflowAwareRenderBox(
        maxHeight: maxHeight,
        truncateAt: truncateAt,
        fadeHeight: fadeHeight,
        fadeColor: fadeColor,
        onOverflowChanged: onOverflowChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _OverflowAwareRenderBox renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..truncateAt = truncateAt
      ..fadeHeight = fadeHeight
      ..fadeColor = fadeColor
      ..onOverflowChanged = onOverflowChanged;
  }
}

class _OverflowAwareRenderBox extends RenderProxyBox {
  _OverflowAwareRenderBox({
    required double maxHeight,
    required double truncateAt,
    required double fadeHeight,
    required Color fadeColor,
    required this.onOverflowChanged,
  }) : _maxHeight = maxHeight, // ignore: prefer_initializing_formals
       _truncateAt = truncateAt, // ignore: prefer_initializing_formals
       _fadeHeight = fadeHeight, // ignore: prefer_initializing_formals
       _fadeColor = fadeColor; // ignore: prefer_initializing_formals

  double _maxHeight;
  double get maxHeight => _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  double _truncateAt;
  double get truncateAt => _truncateAt;
  set truncateAt(double value) {
    if (_truncateAt == value) return;
    _truncateAt = value;
    markNeedsLayout();
  }

  double _fadeHeight;
  double get fadeHeight => _fadeHeight;
  set fadeHeight(double value) {
    if (_fadeHeight == value) return;
    _fadeHeight = value;
    markNeedsPaint();
  }

  Color _fadeColor;
  Color get fadeColor => _fadeColor;
  set fadeColor(Color value) {
    if (_fadeColor == value) return;
    _fadeColor = value;
    markNeedsPaint();
  }

  ValueChanged<bool> onOverflowChanged;

  bool? _lastOverflow;

  /// Most recently measured natural height of the child. Used by callers
  /// that want to predict how much the box will grow if its cap is lifted.
  double _naturalHeight = 0;
  double get naturalHeight => _naturalHeight;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Lay out the child with no vertical bound so its natural height can be
    // observed; then collapse only when it exceeds the trigger threshold.
    final childConstraints = constraints.copyWith(
      minHeight: 0,
      maxHeight: double.infinity,
    );
    child.layout(childConstraints, parentUsesSize: true);
    final natural = child.size.height;
    _naturalHeight = natural;
    final isOverflow = natural > _truncateAt + 0.5;
    final h = isOverflow ? _maxHeight : natural;
    size = constraints.constrain(Size(child.size.width, h));
    if (_lastOverflow != isOverflow) {
      _lastOverflow = isOverflow;
      // Fire after this layout pass so the parent isn't rebuilding inside
      // a layout phase.
      final cb = onOverflowChanged;
      scheduleMicrotask(() => cb(isOverflow));
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final clip = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    context.pushClipRect(needsCompositing, offset, clip.shift(-offset), (
      ctx,
      off,
    ) {
      ctx.paintChild(child, off);
      if (_lastOverflow == true && _fadeHeight > 0) {
        // Paint the fade gradient inside the clipped region — `off` is the
        // top-left in the clip's local coordinates.
        final fadeTop = size.height - _fadeHeight;
        final fadeRect = Rect.fromLTWH(
          off.dx,
          off.dy + fadeTop,
          size.width,
          _fadeHeight,
        );
        final paint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_fadeColor.withValues(alpha: 0), _fadeColor],
          ).createShader(fadeRect);
        ctx.canvas.drawRect(fadeRect, paint);
      }
    });
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Only hit the visible (clipped) area. Without this, the unclipped child
    // would absorb taps in the bottom fade zone before our gesture detector
    // sees them.
    if (position.dx < 0 ||
        position.dy < 0 ||
        position.dx > size.width ||
        position.dy > size.height) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

/// Subtle indicator shown when a note has unsynced local changes. Suppressed
/// for a short window after the change so a freshly-typed note doesn't flash
/// an icon during the normal sync round-trip; appears only if the change is
/// still pending after that.
class _PendingSyncIndicator extends StatefulWidget {
  const _PendingSyncIndicator({required this.note});

  final Note note;

  @override
  State<_PendingSyncIndicator> createState() => _PendingSyncIndicatorState();
}

class _PendingSyncIndicatorState extends State<_PendingSyncIndicator> {
  static const Duration _suppressionWindow = Duration(seconds: 5);

  Timer? _timer;
  bool _pastWindow = false;

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  @override
  void didUpdateWidget(_PendingSyncIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.note.updatedAt != oldWidget.note.updatedAt ||
        widget.note.pending != oldWidget.note.pending) {
      _evaluate();
    }
  }

  void _evaluate() {
    _timer?.cancel();
    _timer = null;
    if (widget.note.pending == null) {
      _pastWindow = false;
      return;
    }
    final elapsed = DateTime.now().difference(widget.note.updatedAt);
    if (elapsed >= _suppressionWindow) {
      _pastWindow = true;
      return;
    }
    _pastWindow = false;
    _timer = Timer(_suppressionWindow - elapsed, () {
      if (mounted) setState(() => _pastWindow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.note.pending == null || !_pastWindow) {
      return const SizedBox.shrink();
    }
    return FTooltip(
      tipBuilder: (context, _) => const Text('Waiting for sync'),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(
          FontAwesomeIcons.cloudArrowUp,
          size: 10,
          color: context.colour.muted.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class NoteCommands extends StatelessWidget {
  const NoteCommands({
    required this.note,
    this.showCommands = false,
    this.tileBg,
    super.key,
  });

  final Note note;
  final bool showCommands;
  final Color? tileBg;

  @override
  Widget build(BuildContext context) {
    // Return empty widget if user is not signed in
    if (!Base.signedIn) {
      return const SizedBox.shrink();
    }

    // Get tags for this note
    final actorId = Base.actorId;
    // Capture accent color before async gap to avoid use_build_context_synchronously
    final accentColor = context.colour.accent;

    // Compute todo/done state
    final selfTodo = note.isAssignedTo(actorId);
    final selfDone = note.isCompletedBy(actorId);
    final todoActors = note.tags[Tag.todo] ?? [];
    final doneActors = note.tags[Tag.done] ?? [];
    final othersTodo = todoActors.where((id) => id != actorId).toList();
    final totalDone = doneActors.length;

    // Resolve assignee names for tooltip (async). Todo names label the
    // "assigned themselves this task" chip; done names label the completion
    // chip (the two sets differ once someone completes).
    final assigneeNamesFuture = note.assignees.isNotEmpty
        ? note.getTagActorNames(Tag.todo)
        : Future.value('');
    final doneNamesFuture = note.completedAssignees.isNotEmpty
        ? note.getTagActorNames(Tag.done)
        : Future.value('');

    // Build generic tag widgets (excluding todo/done which are handled above)
    final threadContacts = context.read<ThreadBloc>().state.thread.contacts;
    final tagFutures = Tag.getAll()
        .where((tag) {
          if (tag == Tag.todo || tag == Tag.done) return false;
          final actors = note.tags[tag];
          if (actors == null || actors.isEmpty) return false;
          // Reply tags: only show current user's
          if (tag == Tag.reply) return actors.contains(actorId);
          // Hide private icon when note access matches thread contacts
          if (tag == Tag.private) {
            return !note.matchesThreadContacts(threadContacts);
          }
          return true;
        })
        .map((tag) async {
          final key = ValueKey(Object.hash(note.id, tag.id));

          final command = ToggleNoteTag(note, tag, actorId);

          // Get actor names for tooltip
          final actorNames = await note.getTagActorNames(tag);

          // Wrap command with subtitle showing actor names
          final wrappedCommand = actorNames.isNotEmpty
              ? CommandWrapper(command, subtitle: Value(actorNames))
              : command;

          final count = tag == Tag.reply
              ? 1
              : TagActors.countOf(note.tags[tag]);

          // Twist tags are display-only (not interactive)
          if (tag == Tag.twist) {
            return CountBadge(
              count: count,
              child: PulsingColorButton(key: key, primaryColor: accentColor),
            );
          }

          return CountBadge(
            count: count,
            child: Button.icon(wrappedCommand, key: key, selected: true),
          );
        })
        .toList();

    // Get activity state for common tags
    final activityBloc = context.watch<ThreadBloc>();

    // Watch the local note_reactions row so active emojis render inline
    // with the other always-visible task buttons (no separate row).

    // Build the final row with tags and commands
    final commandsRow = StreamBuilder<NoteReactionsRow?>(
      stream:
          (Store.get.select(Store.get.noteReactions)
                ..where((t) => t.id.equalsValue(note.id))
                ..limit(1))
              .watchSingleOrNull(),
      builder: (context, reactionSnap) {
        final reactions =
            reactionSnap.data?.reactions ?? const <Reaction, List<ActorId>>{};
        final activeEntries = reactions.entries
            .where((e) => e.value.isNotEmpty)
            .toList(growable: false);

        // Resolve the actors who added each active reaction so they can be
        // shown as a "You, Alice + 2 more" subtitle under the emoji name,
        // matching how count-tags surface their actors.
        final reactionNamesFuture = Future.wait([
          for (final entry in activeEntries)
            Note.formatReactionActorNames(entry.value),
        ]);

        return FutureBuilder<(List<Widget>, String, List<String>, String)>(
          future:
              Future.wait([
                Future.wait(tagFutures),
                assigneeNamesFuture,
                reactionNamesFuture,
                doneNamesFuture,
              ]).then(
                (results) => (
                  results[0] as List<Widget>,
                  results[1] as String,
                  results[2] as List<String>,
                  results[3] as String,
                ),
              ),
          builder: (context, snapshot) {
            final assigneeNames = snapshot.data?.$2 ?? '';
            final reactionNames = snapshot.data?.$3 ?? const <String>[];
            final doneNames = snapshot.data?.$4 ?? '';

            // Active reactions render with the same accent-color "selected"
            // treatment as count-tags — no border, no background. The actors
            // who reacted are shown as a subtitle under the emoji name (empty
            // until the names resolve).
            final activeReactionButtons = <Widget>[
              for (var i = 0; i < activeEntries.length; i++)
                () {
                  final entry = activeEntries[i];
                  final names = i < reactionNames.length
                      ? reactionNames[i]
                      : '';
                  Command cmd = ActiveNoteReaction(note, entry.key);
                  if (names.isNotEmpty) {
                    cmd = CommandWrapper(cmd, subtitle: Value(names));
                  }
                  final btn = Button.icon(
                    cmd,
                    key: ValueKey(Object.hash(note.id, entry.key)),
                    selected: true,
                  );
                  return entry.value.length > 1
                      ? CountBadge(count: entry.value.length, child: btn)
                      : btn;
                }(),
            ];

            // Build task tag widgets — show as many as apply
            final taskTagWidgets = <Widget>[
              // Self todo: circle icon (circleCheck on hover via SelfTaskAction)
              if (selfTodo)
                Button.icon(
                  SelfTaskAction(note),
                  key: ValueKey(Object.hash(note.id, Tag.todo.id, 'self')),
                  selected: true,
                ),
              // Others todo: userCircle chip (circlePlus on hover). Behaves like a
              // reaction — tapping toggles the viewer's own task on/off, surfacing
              // their own self-todo circle before this chip.
              if (othersTodo.isNotEmpty)
                CountBadge(
                  count: othersTodo.length,
                  child: Button.icon(
                    assigneeNames.isNotEmpty
                        ? CommandWrapper(
                            JoinNoteTask(note),
                            subtitle: Value(assigneeNames),
                          )
                        : JoinNoteTask(note),
                    key: ValueKey(Object.hash(note.id, Tag.todo.id, 'others')),
                    selected: true,
                  ),
                ),
              // Any done: single check icon labelled "Done", count badge if > 1.
              // Clicking toggles the viewer's own Tag.done (and clears their todo).
              if (totalDone >= 1)
                (() {
                  Command cmd = ToggleSelfDone(note);
                  if (doneNames.isNotEmpty) {
                    cmd = CommandWrapper(cmd, subtitle: Value(doneNames));
                  }
                  final btn = Button.icon(
                    cmd,
                    key: ValueKey(Object.hash(note.id, Tag.done.id)),
                    selected: true,
                  );
                  return totalDone > 1
                      ? CountBadge(count: totalDone, child: btn)
                      : btn;
                })(),
            ];

            // Build command buttons (only if showCommands is true)
            final commandButtons = showCommands
                ? [
                    // "To do" (circlePlus). Hidden when others are already
                    // assigned — the always-visible userCircle chip is the
                    // self-assign affordance in that case.
                    if (!selfTodo && !selfDone && othersTodo.isEmpty)
                      Button.icon(SelfTaskAction(note)),

                    // Add reaction — opens the emoji picker modal.
                    if (!note.draft)
                      Button.icon(
                        AddNoteReaction(note, activityBloc: activityBloc),
                      ),

                    if (!note.draft)
                      Button.icon(
                        ReplyToNote(note, activityBloc: activityBloc),
                      ),

                    Button.icon(
                      CommandWrapper(
                        ShowNoteCommands(note, activityBloc: activityBloc),
                        icon: Value(PlotIcon.more),
                      ),
                    ),
                  ]
                : <Widget>[];

            // While loading or on error, show buttons without subtitles
            final genericTagButtons =
                snapshot.hasData &&
                    snapshot.connectionState == ConnectionState.done
                ? snapshot.data!.$1
                : Tag.getAll()
                      .where((tag) {
                        if (tag == Tag.todo || tag == Tag.done) return false;
                        final actors = note.tags[tag];
                        if (actors == null || actors.isEmpty) return false;
                        if (tag == Tag.reply) return actors.contains(actorId);
                        if (tag == Tag.private) {
                          return !note.matchesThreadContacts(threadContacts);
                        }
                        return true;
                      })
                      .map((tag) {
                        final key = ValueKey(Object.hash(note.id, tag.id));
                        final command = ToggleNoteTag(note, tag, actorId);
                        final count = tag == Tag.reply
                            ? 1
                            : TagActors.countOf(note.tags[tag]);
                        // Twist tags are display-only (not interactive)
                        if (tag == Tag.twist) {
                          return CountBadge(
                            count: count,
                            child: PulsingColorButton(
                              key: key,
                              primaryColor: context.colour.accent,
                            ),
                          );
                        }
                        return CountBadge(
                          count: count,
                          child: Button.icon(command, key: key, selected: true),
                        );
                      })
                      .toList();

            // Combine task tags, active emoji reactions (always visible),
            // generic tags, and commands (hover-only). Active emojis sit
            // between task tags and the rest so they don't displace the
            // todo/done buttons but always read before hover-only chrome.
            final allButtons = [
              ...taskTagWidgets,
              ...activeReactionButtons,
              ...genericTagButtons,
              ...commandButtons,
            ];

            // Use LayoutBuilder to dynamically truncate buttons based on available width
            return LayoutBuilder(
              builder: (context, constraints) {
                // If width is unbounded (infinite), show all buttons
                if (!constraints.maxWidth.isFinite) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: allButtons,
                  );
                }

                // Estimate button width (icon buttons are approximately 40px with spacing)
                const estimatedButtonWidth = 40.0;
                final maxButtons = (constraints.maxWidth / estimatedButtonWidth)
                    .floor();

                // Determine which buttons to show
                List<Widget> visibleButtons;
                if (allButtons.length <= maxButtons) {
                  // All buttons fit
                  visibleButtons = allButtons;
                } else if (maxButtons <= 1) {
                  // Only show the last button (ShowNoteCommands) if space is very limited
                  visibleButtons = allButtons.isNotEmpty
                      ? [allButtons.last]
                      : [];
                } else {
                  // Truncate from the end, but always keep the last button
                  visibleButtons = [
                    ...allButtons.sublist(0, maxButtons - 1),
                    allButtons.last,
                  ];
                }

                if (visibleButtons.isEmpty) {
                  return const SizedBox.shrink();
                }
                final buttonRow = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: visibleButtons,
                );
                final bg = tileBg;
                if (bg == null) return buttonRow;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ColoredBox(color: bg, child: buttonRow),
                    Container(
                      width: 24,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [bg, bg.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    return commandsRow;
  }
}

/// Renders a note's action attachments.
///
/// External links display as full-width thin rows (mirroring the pinned
/// thread-link row), so they're rendered in a vertical Column. All other
/// action types (callbacks, files, conferencing links, etc.) remain in a
/// horizontal Wrap below — they're chip-shaped and read better side by side.
class _NoteActionsLayout extends StatelessWidget {
  const _NoteActionsLayout({required this.actions, required this.note});

  final List<UserAction> actions;
  final Note note;

  @override
  Widget build(BuildContext context) {
    final externalLinks = <(int, UserAction)>[];
    final others = <(int, UserAction)>[];
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      if (action.type == UserActionType.external) {
        externalLinks.add((i, action));
      } else {
        others.add((i, action));
      }
    }

    final children = <Widget>[];
    for (final (idx, link) in externalLinks) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: NoteActionWidget(link: link, note: note, actionIndex: idx),
        ),
      );
    }
    if (others.isNotEmpty) {
      children.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: others
              .map(
                ((int, UserAction) entry) => NoteActionWidget(
                  link: entry.$2,
                  note: note,
                  actionIndex: entry.$1,
                  variant: FButtonVariant.secondary,
                  style: FButtonStyleDelta.delta(
                    contentStyle: FButtonContentStyleDelta.delta(
                      padding: EdgeInsetsGeometryDelta.value(
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      ),
                    ),
                  ),
                  textStyle: context.theme.typography.sm,
                ),
              )
              .toList(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
