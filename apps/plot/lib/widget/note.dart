import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/store/store.dart';
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
    super.key,
  });

  final Note note;
  final bool selected;
  final bool dimmed;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;
  final bool showAuthor;

  @override
  State<NoteWidget> createState() => _NoteWidgetState();
}

class _NoteWidgetState extends State<NoteWidget> {
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
              child: Viewer(markdown: noteContent),
            ),
          if (noteLinks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: 6,
                right: 6,
                top: 8,
                bottom: 4,
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: noteLinks
                    .map(
                      (link) => NoteActionWidget(
                        link: link,
                        note: widget.note,
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
            ),
          SizedBox(
            height: 30,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // NoteCommands can expand to full width
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
                      showCommands: highlighted,
                    ),
                  ),
                ),
                // Author/timestamp positioned on the right, overlapping if needed
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: widget.showAuthor
                      ? FutureBuilder<Actor?>(
                          future: widget.note.getAuthor(),
                          builder: (context, snapshot) {
                            final actor = snapshot.data;
                            final authorName = actor == null
                                ? null
                                : (widget.note.authorId.isCurrentUser
                                      ? 'You'
                                      : actor.nameOrEmail);
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (authorName != null &&
                                    authorName.isNotEmpty) ...[
                                  if (actor?.email != null &&
                                      actor!.email != authorName)
                                    FTooltip(
                                      tipBuilder: (context, controller) =>
                                          Text(actor.email!),
                                      child: Text(
                                        authorName,
                                        style: context.theme.typography.xs
                                            .copyWith(
                                              color: context.colour.muted,
                                            ),
                                      ),
                                    )
                                  else
                                    Text(
                                      authorName,
                                      style: context.theme.typography.xs
                                          .copyWith(
                                            color: context.colour.muted,
                                          ),
                                    ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '•',
                                    style: context.theme.typography.xs.copyWith(
                                      color: context.colour.muted,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                FTooltip(
                                  tipBuilder: (context, controller) => Text(
                                    widget.note.sourceCreatedAt
                                        .toLocal()
                                        .format('MMM d, yyyy, h:mm a'),
                                  ),
                                  child: Text(
                                    widget.note.sourceCreatedAt.toTimeAgo(),
                                    style: context.theme.typography.xs.copyWith(
                                      color: context.colour.muted,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        )
                      : FTooltip(
                          tipBuilder: (context, controller) => Text(
                            widget.note.sourceCreatedAt.toLocal().format(
                              'MMM d, yyyy, h:mm a',
                            ),
                          ),
                          child: Text(
                            widget.note.sourceCreatedAt.toTimeAgo(),
                            style: context.theme.typography.xs.copyWith(
                              color: context.colour.muted,
                            ),
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
      return Opacity(opacity: 0.4, child: result);
    }
    return result;
  }
}

class NoteCommands extends StatelessWidget {
  const NoteCommands({
    required this.note,
    this.showCommands = false,
    super.key,
  });

  final Note note;
  final bool showCommands;

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
    final othersDone = doneActors.where((id) => id != actorId).toList();
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
    final tagFutures = Tag.getAll()
        .where((tag) {
          if (tag == Tag.todo || tag == Tag.done) return false;
          final actors = note.tags[tag];
          if (actors == null || actors.isEmpty) return false;
          // Reply tags: only show current user's
          if (tag == Tag.reply) return actors.contains(actorId);
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
          // Any done: check icon with count if > 1
          if (totalDone == 1 && othersDone.isEmpty)
            Button.icon(
              ToggleNoteTag(note, Tag.done, actorId),
              key: ValueKey(Object.hash(note.id, Tag.done.id)),
              selected: true,
            ),
          if (totalDone == 1 && othersDone.isNotEmpty)
            Button.icon(
              CommandWrapper(
                assigneeNames.isNotEmpty
                    ? CommandWrapper(
                        PickNoteAssignee(note),
                        subtitle: Value(assigneeNames),
                      )
                    : PickNoteAssignee(note),
                icon: const Value(PlotIcon.selfTaskDone),
              ),
              key: ValueKey(Object.hash(note.id, Tag.done.id)),
              selected: true,
            ),
          if (totalDone >= 2)
            CountBadge(
              count: totalDone,
              child: Button.icon(
                CommandWrapper(
                  assigneeNames.isNotEmpty
                      ? CommandWrapper(
                          PickNoteAssignee(note),
                          subtitle: Value(assigneeNames),
                        )
                      : PickNoteAssignee(note),
                  icon: const Value(PlotIcon.selfTaskDone),
                ),
                key: ValueKey(Object.hash(note.id, Tag.done.id)),
                selected: true,
              ),
            ),
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
                if (!note.hasTag(Tag.todo, actorId) &&
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

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: visibleButtons,
            );
          },
        );
      },
    );
  }
}
