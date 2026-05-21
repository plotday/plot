import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/note_viewer.dart';
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

    final listTile = ListTile(
      padding: const EdgeInsets.only(left: 10, right: 16, top: 8),
      borderRadius: BorderRadius.circular(8),
      bodyBuilder: (context, highlighted) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              child: _NoteActionsLayout(
                actions: noteLinks,
                note: widget.note,
              ),
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

/// Inline note content with a maximum height. When the rendered Viewer
/// exceeds the cap, the bottom is faded out and a "View all" affordance
/// appears on hover; tapping the fade or the affordance opens the full
/// note in [NoteViewer] via [NoteViewerBloc].
class _TruncatedNoteContent extends StatefulWidget {
  const _TruncatedNoteContent({required this.note, this.searchHighlight});

  final Note note;
  final String? searchHighlight;

  /// Maximum height of inline content before truncation kicks in. Long
  /// notes get clipped to this and reveal the rest via the full viewer.
  static const double maxHeight = 360.0;

  /// Height of the bottom fade gradient overlaid on truncated content.
  static const double fadeHeight = 80.0;

  @override
  State<_TruncatedNoteContent> createState() => _TruncatedNoteContentState();
}

class _TruncatedNoteContentState extends State<_TruncatedNoteContent> {
  bool _overflow = false;
  bool _hovered = false;

  void _openViewer() {
    context.read<NoteViewerBloc>().view(widget.note);
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.note.content ?? '';
    final viewer = Viewer(
      markdown: content,
      searchHighlight: widget.searchHighlight,
    );

    final measured = _OverflowAwareBox(
      maxHeight: _TruncatedNoteContent.maxHeight,
      onOverflowChanged: (overflow) {
        if (!mounted || overflow == _overflow) return;
        setState(() => _overflow = overflow);
      },
      child: viewer,
    );

    if (!_overflow) return measured;

    final bg = context.colour.background;
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Stack(
        children: [
          measured,
          // Bottom fade — also catches taps to open the viewer.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _TruncatedNoteContent.fadeHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openViewer,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg.withValues(alpha: 0), bg],
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          if (_hovered)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: const _ViewAllPill(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ViewAllPill extends StatelessWidget {
  const _ViewAllPill();

  @override
  Widget build(BuildContext context) {
    final fg = context.theme.colors.foreground;
    final bg = context.colour.background;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: context.theme.colors.border,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.upRightAndDownLeftFromCenter,
            size: 12,
            color: fg,
          ),
          const SizedBox(width: 6),
          Text(
            'View all',
            style: context.theme.typography.sm.copyWith(
              color: fg,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lays out [child] with unbounded vertical constraints, captures its
/// natural height, and clamps its own height to [maxHeight]. Reports
/// whether truncation was necessary via [onOverflowChanged].
class _OverflowAwareBox extends SingleChildRenderObjectWidget {
  const _OverflowAwareBox({
    required this.maxHeight,
    required this.onOverflowChanged,
    required Widget super.child,
  });

  final double maxHeight;
  final ValueChanged<bool> onOverflowChanged;

  @override
  _OverflowAwareRenderBox createRenderObject(BuildContext context) =>
      _OverflowAwareRenderBox(
        maxHeight: maxHeight,
        onOverflowChanged: onOverflowChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _OverflowAwareRenderBox renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..onOverflowChanged = onOverflowChanged;
  }
}

class _OverflowAwareRenderBox extends RenderProxyBox {
  _OverflowAwareRenderBox({
    required double maxHeight,
    required this.onOverflowChanged,
  }) : _maxHeight = maxHeight;

  double _maxHeight;
  double get maxHeight => _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  ValueChanged<bool> onOverflowChanged;

  bool? _lastOverflow;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Lay out the child with no vertical bound so its natural height can be
    // observed; then size ourselves to min(natural, maxHeight).
    final childConstraints = constraints.copyWith(
      minHeight: 0,
      maxHeight: double.infinity,
    );
    child.layout(childConstraints, parentUsesSize: true);
    final natural = child.size.height;
    final isOverflow = natural > _maxHeight + 0.5;
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

    // Resolve assignee names for tooltip (async)
    final assigneeNamesFuture = note.assignees.isNotEmpty
        ? note.getTagActorNames(Tag.todo)
        : Future.value('');

    // Build generic tag widgets (excluding todo/done which are handled above)
    final isViewerPriority = context
        .read<ThreadBloc>()
        .state
        .thread
        .priority
        .isViewer;
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

          final command = ToggleNoteTag(
            note,
            tag,
            actorId,
            isViewer: isViewerPriority,
          );

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
    final activityState = activityBloc.state;

    // Build the final row with tags and commands
    return FutureBuilder<(List<Widget>, String)>(
      future: Future.wait([
        Future.wait(tagFutures),
        assigneeNamesFuture,
      ]).then((results) => (results[0] as List<Widget>, results[1] as String)),
      builder: (context, snapshot) {
        final assigneeNames = snapshot.data?.$2 ?? '';

        // Wrap PickNoteAssignee with assignee names subtitle
        Command assigneeCommand = PickNoteAssignee(note);
        if (assigneeNames.isNotEmpty) {
          assigneeCommand = CommandWrapper(
            assigneeCommand,
            subtitle: Value(assigneeNames),
          );
        }

        // Build task tag widgets — show as many as apply
        final taskTagWidgets = <Widget>[
          // Self todo: circle icon (circleCheck on hover via SelfTaskAction)
          if (selfTodo)
            Button.icon(
              SelfTaskAction(note),
              key: ValueKey(Object.hash(note.id, Tag.todo.id, 'self')),
              selected: true,
            ),
          // Others todo: assigned icon with count
          if (othersTodo.isNotEmpty)
            CountBadge(
              count: othersTodo.length,
              child: Button.icon(
                assigneeCommand,
                key: ValueKey(Object.hash(note.id, Tag.todo.id, 'others')),
                selected: true,
              ),
            ),
          // Any done: single check icon labelled "Done", count badge if > 1.
          // Clicking always toggles the viewer's own Tag.done.
          if (totalDone >= 1)
            (() {
              Command cmd = ToggleNoteTag(note, Tag.done, actorId);
              if (assigneeNames.isNotEmpty) {
                cmd = CommandWrapper(cmd, subtitle: Value(assigneeNames));
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
        final isViewer = activityState.thread.priority.isViewer;
        final commandButtons = showCommands
            ? [
                if (!selfTodo && !selfDone && !isViewer)
                  Button.icon(SelfTaskAction(note)),
                if (othersTodo.isEmpty && !isViewer)
                  Button.icon(
                    CommandWrapper(
                      PickNoteAssignee(note),
                      title: 'Assign',
                      icon: const Value(PlotIcon.assignAdd),
                    ),
                  ),
                if (totalDone == 0 &&
                    !note.hasTag(Tag.todo, actorId) &&
                    !note.hasTag(Tag.done, actorId))
                  Button.icon(ToggleNoteTag(note, Tag.done, actorId)),

                if (!note.draft && !isViewer)
                  Button.icon(ReplyToNote(note, activityBloc: activityBloc)),

                // Add top tag buttons
                ...topNoteTags(
                  note,
                  activityState.tagSuggestions,
                  actorId,
                ).map((cmd) => Button.icon(cmd)),
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
            snapshot.hasData && snapshot.connectionState == ConnectionState.done
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
                    final command = ToggleNoteTag(
                      note,
                      tag,
                      actorId,
                      isViewer: isViewerPriority,
                    );
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

        // Combine task tags, generic tags, and commands
        final allButtons = [
          ...taskTagWidgets,
          ...genericTagButtons,
          ...commandButtons,
        ];

        // Use LayoutBuilder to dynamically truncate buttons based on available width
        return LayoutBuilder(
          builder: (context, constraints) {
            // If width is unbounded (infinite), show all buttons
            if (!constraints.maxWidth.isFinite) {
              return Row(mainAxisSize: MainAxisSize.min, children: allButtons);
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
              visibleButtons = allButtons.isNotEmpty ? [allButtons.last] : [];
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
    final externalLinks = <UserAction>[];
    final others = <UserAction>[];
    for (final action in actions) {
      if (action.type == UserActionType.external) {
        externalLinks.add(action);
      } else {
        others.add(action);
      }
    }

    final children = <Widget>[];
    for (final link in externalLinks) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: NoteActionWidget(link: link, note: note),
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
                (link) => NoteActionWidget(
                  link: link,
                  note: note,
                  variant: FButtonVariant.secondary,
                  style: FButtonStyleDelta.delta(
                    contentStyle: FButtonContentStyleDelta.delta(
                      padding: EdgeInsetsGeometryDelta.value(
                        const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
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
