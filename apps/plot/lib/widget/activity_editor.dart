import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/api/twist_api.dart';

class ActivityEditor extends StatefulWidget {
  const ActivityEditor({required this.draft, this.expand = false, super.key});

  final Activity draft;
  final bool expand;

  @override
  State<ActivityEditor> createState() => ActivityEditorState();
}

class ActivityEditorState extends State<ActivityEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey<EditableAreaState> _editableAreaKey =
      GlobalKey<EditableAreaState>();
  bool _isEmpty = true;

  /// Request focus on the editor
  void focus() {
    _editableAreaKey.currentState?.focus();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return EditableArea(
          key: _editableAreaKey,
          position: EditableAreaPosition.bottom,
          builder: (context, focusNode) {
            return Column(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (widget.expand)
                  Expanded(
                    key: const ValueKey('editor_expanded'),
                    child: Editor(
                      key: _editorKey,
                      hint: 'Add activity',
                      autofocus: true,
                      focusNode: focusNode,
                      twists: state.twists,
                      shrinkWrap: false,
                      onChange: (value) {
                        setState(() {
                          _isEmpty = value.trim().isEmpty;
                        });
                      },
                      onSubmitted: (body, {bool alt = false}) async {
                        await context.run(
                          AddActivity(
                            finalizeDraft(body, twists: state.twists, alt: alt),
                          ),
                        );
                      },
                    ),
                  )
                else
                  Editor(
                    key: _editorKey,
                    hint: 'Add activity',
                    autofocus: true,
                    focusNode: focusNode,
                    twists: state.twists,
                    onChange: (value) {
                      setState(() {
                        _isEmpty = value.trim().isEmpty;
                      });
                    },
                    onSubmitted: (body, {bool alt = false}) async {
                      await context.run(
                        AddActivity(
                          finalizeDraft(body, twists: state.twists, alt: alt),
                        ),
                      );
                    },
                  ),
                // Bottom bar - stays at bottom, above keyboard
                Row(
                  children: [
                    // Left side: Do Now toggle
                    Button.icon(
                      StartActivity(widget.draft),
                      selected: widget.draft.doNow,
                    ),
                    const Spacer(),
                    // Right side: Save button
                    Button.icon(
                      CommandWrapper(
                        AddActivity(Future.value(widget.draft)),
                        run: (action, context) async {
                          _editorKey.currentState?.submit(false);
                          return const CommandDone();
                        },
                      ),
                      style: ButtonStyle.primary,
                      enabled: !_isEmpty,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<Activity> finalizeDraft(
    String body, {
    required List<PriorityTwist> twists,
    required bool alt,
  }) async {
    // Parse mentions from the note (stored as [#@ID])
    final mentions = Activity.parseMentionsFromNote(body, twists);

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.draft.at != null;

    return widget.draft.copyWith(
      note: Value(body),
      draft: false,
      mentions: Value(mentions.isEmpty ? null : mentions),
      // Create task with scheduling only if Cmd-Enter was used
      type: shouldSchedule ? ActivityType.action : null,
      on: shouldSchedule && !hasDateTime
          ? Value(CustomDateRange(Date.today(), null))
          : const Value.absent(),
      at: shouldSchedule && hasDateTime
          ? Value(
              DateTimeRange(
                DateTime.now(),
                DateTime.now().add(Duration(hours: 1)),
              ),
            )
          : const Value.absent(),
    );
  }
}
