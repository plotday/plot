import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/action/action.dart';
import 'package:plot/api/twist_api.dart';

class ActivityEditor extends StatefulWidget {
  const ActivityEditor({required this.draft, this.expand = false, super.key});

  final Activity draft;
  final bool expand;

  @override
  State<ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<ActivityEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return EditableArea(
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
                      onSubmitted: (body, {bool alt = false}) async {
                        await context.run(StartActivity(widget.draft));
                        if (!context.mounted) return;
                        await context.run(
                          AddActivity(finalizeDraft(body, twists: state.twists)),
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
                    onSubmitted: (body, {bool alt = false}) async {
                      await context.run(StartActivity(widget.draft));
                      if (!context.mounted) return;
                      await context.run(
                        AddActivity(finalizeDraft(body, twists: state.twists)),
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
                      expand: false,
                    ),
                    const Spacer(),
                    // Right side: Save button
                    Button.icon(
                      ActionWrapper(
                        AddActivity(Future.value(widget.draft)),
                        run: (action, context) async {
                          _editorKey.currentState?.submit(false);
                          return const ActionDone();
                        },
                      ),
                      expand: false,
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
  }) async {
    // Parse mentions from the note (stored as [#@ID])
    final mentions = Activity.parseMentionsFromNote(body, twists);

    return widget.draft.copyWith(
      note: Value(body),
      draft: false,
      mentions: Value(mentions.isEmpty ? null : mentions),
    );
  }
}
