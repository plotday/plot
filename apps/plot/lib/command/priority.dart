import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/page/page.dart';
import 'package:plot/router.dart';

class PriorityCommand extends ValueCommand<Priority?> {
  PriorityCommand(
    this.priority,
  ) : super(
          title: priority?.name ?? 'All Priorities',
          icon: const PlotIcon.priority(),
          value: priority,
        );

  final Priority? priority;

  @override
  Widget build(
    BuildContext context, {
    bool selected = false,
    void Function()? onTap,
  }) =>
      ListTile(
        leading: icon,
        title: PriorityLabel(priority: priority),
        subtitle: subtitle != null ? Text(subtitle!) : null,
        selected: selected,
        onTap: onTap,
      );
}

class PickPriority extends StaticCommands {
  static Future<Priority?> show({
    required BuildContext context,
    Priority? defaultPriority,
  }) async {
    return await CommandBar.show(
      context,
      PickPriority(
        prompt: 'Pick a priority',
        priorities: context.read<PriorityBloc>().state.recent,
      ),
    );
  }

  PickPriority({
    required this.priorities,
    required super.prompt,
  }) : super(commands: [
          CommandGroup(
            title: 'Recent',
            commands: priorities
                .map((priority) => PriorityCommand(priority))
                .toList(),
          ),
        ]);

  final List<Priority?> priorities;
}

class ChangePriority extends ShowCommand<Priority> {
  ChangePriority()
      : super(
          title: 'Switch priorities',
          icon: const PlotIcon.priority(),
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyJ,
            meta: true,
          ),
          commands: (context) => PickPriority(
            prompt: 'Switch priorities',
            priorities: context.read<PriorityBloc>().state.recent,
          ),
        );

  @override
  void onSelect(BuildContext context, Priority? value) async {
    PriorityRoute.byId(value?.id).go(context);
  }
}

class NewPriority extends Command {
  NewPriority()
      : super(
          title: 'New priority',
        );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandPage(const NewPriorityPage());
  }
}
