import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'action.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/edit_priority.dart';
import 'package:plot/state/priority.dart';

abstract class PriorityAction extends Action {
  PriorityAction(
    this.priority, {
    required super.eventObject,
    required super.eventAction,
  }) : super(
         title: priority?.title ?? 'None',
         subtitle: priority?.ancestorsLabel(),
       );

  final Priority? priority;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (priority?.ancestorsLabel().isNotEmpty == true) ...[
          Flexible(
            child: Text(
              priority!.ancestorsLabel(),
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.sm.copyWith(
                color: context.colour.muted,
              ),
            ),
          ),
          Text(
            Priority.separator,
            style: context.theme.typography.sm.copyWith(
              color: context.colour.muted,
            ),
          ),
        ],
        Flexible(
          child: Text(
            priority?.title ?? 'None',
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.sm.copyWith(
              color: context.colour.foreground,
            ),
          ),
        ),
      ],
    );
  }
}

class ChangeCurrentPriority extends PriorityAction {
  ChangeCurrentPriority(Priority priority)
    : super(
        priority,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  @override
  Future<ActionReturn> run(BuildContext context) async {
    return ActionRoute(
      PriorityRoute(priorityIdString: priority!.id.toShortString()),
    );
  }
}

class PriorityGroup extends ActionGroup {
  PriorityGroup({required super.title, required this.builder});

  final Action Function(Priority? priority) builder;

  @override
  Future<List<Action>> list({String? search}) async {
    final all = (await Priority.get(
      order: PriorityOrder.recent,
      search: search,
    )).map((priority) => builder(priority)).toList();
    return ActionGroup.filter(all, search);
  }
}

class ChangeCurrentPriorityActions extends Actions {
  ChangeCurrentPriorityActions({
    super.prompt = 'Change Current Priority',
    Priority? initialPriority,
  }) : super(
         groups: [
           PriorityGroup(
             title: 'Change Current Priority',
             builder: (priority) => ChangeCurrentPriority(priority!),
           ),
         ],
         secondaryAction: (prompt) => NewPriority(parent: initialPriority),
       );
}

class OpenPriority extends Action {
  OpenPriority(Priority priority)
    : priorityId = priority.id,
      super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  OpenPriority.byId(this.priorityId)
    : super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  final PriorityId priorityId;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    return ActionRoute(
      PriorityRoute(priorityIdString: priorityId.toShortString()),
    );
  }
}

class PickCurrentPriority extends ShowActions {
  PickCurrentPriority()
    : super(
        title: 'Switch Priorities',
        icon: PlotIcon.priority,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        actions: (context) => Future.value(ChangeCurrentPriorityActions()),
      );
}

class AddPriority extends Action {
  AddPriority(this._priority)
    : super(
        title: 'Add',
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    return ActionRoute(
      PriorityRoute(priorityIdString: priority.id.toShortString()),
      replace: true,
    );
  }
}

class EditPriority extends Action {
  EditPriority(this._priority)
    : super(
        title: 'Save',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Future<Priority> _priority;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    return const ActionDone();
  }
}

class ArchivePriority extends Action {
  ArchivePriority(this._priority)
    : super(
        title: 'Archive',
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Priority> _priority;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final priority = await _priority;
    if (priority.root) {
      return ActionMessage(
        "The default priority can't be archived",
        isError: true,
      );
    }
    await priority.delete();
    return const ActionDone();
  }
}

class NewPriority extends ShowPage {
  NewPriority({Priority? parent})
    : super(
        title: parent == null ? 'Add a Priority' : 'Add a Sub-priority',
        icon: PlotIcon.add,
        builder: (context) => EditPriorityPage(parent: parent),
      );
}

class EditPriorityAction extends ShowPage {
  EditPriorityAction(Priority priority)
    : super(
        title: 'Edit',
        icon: PlotIcon.settings,
        builder: (context) => EditPriorityPage(priority: priority),
      );
}

class ShowPriorityActions extends ShowActions {
  ShowPriorityActions(Priority priority, {bool current = false})
    : super(
        title: 'More Actions',
        icon: PlotIcon.menu,
        actions: (context) => Future.value(
          Actions(
            groups: [
              StaticActionGroup(
                title: priority.title,
                actions: current
                    ? currentPriorityActions(priority)
                    : priorityActions(priority),
              ),
            ],
          ),
        ),
      );
}

List<Action> prioritySecondaryActions(Priority priority) => [
  EditPriorityAction(priority),
  ManageAgents(priority),
  if (!priority.root) SetTopPriority(priority, priority.topOrder == null),
  if (!priority.root) ArchivePriority(Future.value(priority)),
  NewPriority(parent: priority),
];

List<Action> priorityActions(Priority priority) => [
  OpenPriority(priority),
  ...prioritySecondaryActions(priority),
];

List<Action> currentPriorityActions(Priority priority) => [
  ...prioritySecondaryActions(priority),
  NewActivity(),
];

class SetTopPriority extends Action {
  SetTopPriority(this.priority, this.add)
    : super(
        title: add ? 'Add to Top Priorities' : 'Remove From Top Priorities',
        eventObject: EventObject.priority,
        eventAction: add ? EventAction.pinned : EventAction.unpinned,
        icon: add ? PlotIcon.add : PlotIcon.remove,
      );

  final Priority priority;
  final bool add;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    await priority
        .copyWith(topOrder: add ? Value(Order.first()) : const Value(null))
        .save();
    return const ActionDone();
  }
}

class ToggleShowArchived extends Action {
  ToggleShowArchived({required this.showArchived})
    : super(
        title: showArchived ? 'Show Active Items' : 'Show Archived Items',
        subtitle: showArchived ? 'Hide archived items' : 'Show archived items',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  final bool showArchived;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleShowArchived();
    return const ActionDone();
  }
}
