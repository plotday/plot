import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/activity.dart';

class NoteWidget extends StatefulWidget {
  const NoteWidget({
    required this.note,
    this.selected = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.showAuthor = true,
    super.key,
  });

  final Note note;
  final bool selected;
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
    final noteLinks = widget.note.links ?? [];

    return ListTile(
      padding: const .only(left: 10, right: 16, top: 8),
      bodyBuilder: (context, highlighted) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                spacing: 8,
                runSpacing: 8,
                children: noteLinks
                    .map((link) => NoteLinkWidget(link: link))
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
                  child: NoteCommands(
                    note: widget.note,
                    showCommands: highlighted,
                  ),
                ),
                // Author/timestamp positioned on the right, overlapping if needed
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: widget.showAuthor
                      ? FutureBuilder<String>(
                          future: widget.note.getAuthorName(),
                          builder: (context, snapshot) {
                            final authorName = snapshot.data;
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (authorName != null &&
                                    authorName.isNotEmpty) ...[
                                  Text(
                                    authorName,
                                    style: context.theme.typography.xs.copyWith(
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
                                Text(
                                  widget.note.sourceCreatedAt.toTimeAgo(),
                                  style: context.theme.typography.xs.copyWith(
                                    color: context.colour.muted,
                                  ),
                                ),
                              ],
                            );
                          },
                        )
                      : Text(
                          widget.note.sourceCreatedAt.toTimeAgo(),
                          style: context.theme.typography.xs.copyWith(
                            color: context.colour.muted,
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
      noHoverHighlight: true,
    );
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
    final tagFutures = Tag.getAll()
        .where((tag) {
          // Show tags if ANY actor has them (not just current user)
          final actors = note.tags[tag];
          return actors != null && actors.isNotEmpty;
        })
        .map((tag) async {
          final key = ValueKey(Object.hash(note.id, tag.id));

          // Use FinishTask when clicking Tag.now (matching ActivityWidget behavior)
          final command = tag == Tag.now
              ? FinishTask(note)
              : ToggleNoteTag(note, tag, actorId);

          // Get actor names for tooltip
          final actorNames = await note.getTagActorNames(tag);

          // Wrap command with subtitle showing actor names
          final wrappedCommand = actorNames.isNotEmpty
              ? CommandWrapper(command, subtitle: Value(actorNames))
              : command;

          return Button.icon(wrappedCommand, key: key, selected: true);
        })
        .toList();

    // Get activity state for common tags
    final activityState = context.watch<ActivityBloc>().state;

    // Get commands (only if showCommands is true)
    final commandButtons = showCommands
        ? [
            if (!note.isAssigned()) ...[
              Button.icon(StartTask(note)),
              Button.icon(FinishTask(note)),
            ],
            // Add top tag buttons
            ...topNoteTags(
              note,
              activityState.tagSuggestions,
              actorId,
            ).map((cmd) => Button.icon(cmd)),
            Button.icon(
              CommandWrapper(
                ShowNoteCommands(note),
                icon: Value(PlotIcon.more),
              ),
            ),
          ]
        : <Widget>[];

    // Build the final row with tags and commands
    return FutureBuilder<List<Widget>>(
      future: Future.wait(tagFutures),
      builder: (context, snapshot) {
        // While loading or on error, show buttons without subtitles
        final loadedTagButtons =
            snapshot.hasData && snapshot.connectionState == ConnectionState.done
            ? snapshot.data!
            : Tag.getAll()
                  .where((tag) {
                    final actors = note.tags[tag];
                    return actors != null && actors.isNotEmpty;
                  })
                  .map((tag) {
                    final key = ValueKey(Object.hash(note.id, tag.id));
                    final command = tag == Tag.now
                        ? FinishTask(note)
                        : ToggleNoteTag(note, tag, actorId);
                    return Button.icon(command, key: key, selected: true);
                  })
                  .toList();

        // Combine tags and commands
        final allButtons = [...loadedTagButtons, ...commandButtons];

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
