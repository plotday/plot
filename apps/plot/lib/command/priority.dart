import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/command_bar.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';

class PickPriority extends Commands {
  static Future<Priority?> show({
    required BuildContext context,
    Priority? defaultPriority,
  }) async {
    return await CommandBar.show(
      context,
      PickPriority(
        title: 'Pick a priority',
        priorities: context.read<PriorityBloc>().state.recent,
      ),
    );
  }

  PickPriority({
    required this.priorities,
    required super.title,
  }) : super(prompt: 'Search priorities');

  final List<Priority> priorities;

  @override
  Future<List<CommandGroup>> list({String? search}) async {
    return [
      CommandGroup(
        title: 'Recent',
        commands: priorities
            .map((priority) => ValueCommand(
                  title: priority.name,
                  icon: const PlotIcon.priority(),
                  value: priority,
                ))
            .toList(),
      ),
    ];
  }
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
            title: 'Switch priorities',
            priorities: context.read<PriorityBloc>().state.recent,
          ),
        );

  @override
  void onSelect(BuildContext context, Priority? value) async {
    context.read<PriorityBloc>().setCurrent(value);
  }
}
