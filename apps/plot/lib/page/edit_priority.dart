import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/action/action.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/state/priorities.dart';

class EditPriorityPage extends HookWidget {
  const EditPriorityPage({Priority? parent, Priority? priority, super.key})
    : _initialParent = parent,
      _priority = priority;

  final Priority? _initialParent;
  final Priority? _priority;

  bool get isEditing => _priority != null;

  @override
  Widget build(BuildContext context) {
    final (nameController, title) = useTextEditingValue(
      initialValue: _priority?.title ?? '',
    );
    final parent = useState<Priority?>(_initialParent);

    Future<void> submitPriority() async {
      if (title.isEmpty) return;

      final buildContext = context;
      ActionReturn? result;
      if (isEditing) {
        // Edit existing priority
        final action = EditPriority(
          Future.value(_priority!.copyWith(title: title)),
        );
        result = await action.run(buildContext);
      } else {
        // Create new priority
        final prioritiesBloc = buildContext.read<PrioritiesBloc>();
        final effectiveParent = parent.value ?? prioritiesBloc.state.root!;
        final action = AddPriority(
          Future.value(Priority(title: title, parent: effectiveParent)),
        );
        result = await action.run(buildContext);
      }

      if (buildContext.mounted) {
        Dialog.pop(buildContext, Value(result));
      }
    }

    final fieldLabel = isEditing ? "Edit priority" : "Add a priority";

    return Column(
      spacing: 16,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: nameController,
          label: fieldLabel,
          maxLines: 1,
          autofocus: true,
          onSubmitted: (_) => submitPriority(),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Builder(
              builder: (context) {
                final prioritiesBloc = context.read<PrioritiesBloc>();
                return Button.primary(
                  ActionWrapper(
                    isEditing
                        ? EditPriority(
                            Future.value(_priority!.copyWith(title: title)),
                          )
                        : AddPriority(
                            Future(() async {
                              final effectiveParent =
                                  parent.value ??
                                  prioritiesBloc.state.root ??
                                  await Priority.getDefault();
                              return Priority(
                                title: title,
                                parent: effectiveParent,
                              );
                            }),
                          ),
                    run: (action, context) async {
                      await submitPriority();
                      return const ActionDone();
                    },
                  ),
                  enabled: title.isNotEmpty,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}
