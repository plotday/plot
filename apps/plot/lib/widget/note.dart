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
    super.key,
  });

  final Note note;
  final bool selected;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  @override
  State<NoteWidget> createState() => _NoteWidgetState();
}

class _NoteWidgetState extends State<NoteWidget> {
  bool _isHovered = false;

  bool get _showCommands => _isHovered || (widget.focusNode?.hasFocus ?? false);

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

  void _setHovered(bool hovered) {
    if (_isHovered != hovered) {
      setState(() {
        _isHovered = hovered;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final noteContent = widget.note.content ?? '';
    final noteLinks = widget.note.links ?? [];

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: ListTile(
        padding: const EdgeInsets.only(left: 8, right: 8, top: 4),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (noteContent.isNotEmpty) Viewer(markdown: noteContent),
            if (noteLinks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: noteLinks
                      .map((link) => NoteLinkWidget(link: link))
                      .toList(),
                ),
              ),
            SizedBox(
              height:
                  35, // Fixed height matching icon button height (20px icon + 7.5px padding top/bottom)
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: NoteCommands(
                      note: widget.note,
                      showCommands: _showCommands,
                    ),
                  ),
                  Text(
                    widget.note.createdAt.toTimeAgo(),
                    style: context.theme.typography.xs.copyWith(
                      color: context.colour.muted,
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
      ),
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

          // Use FinishNote when clicking Tag.now (matching ActivityWidget behavior)
          final command = tag == Tag.now
              ? FinishNote(note)
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
            Button.icon(StartTask(note)),
            Button.icon(FinishNote(note)),
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
                        ? FinishNote(note)
                        : ToggleNoteTag(note, tag, actorId);
                    return Button.icon(command, key: key, selected: true);
                  })
                  .toList();

        // Combine tags and commands
        final allButtons = [...loadedTagButtons, ...commandButtons];

        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: allButtons,
        );
      },
    );
  }
}
