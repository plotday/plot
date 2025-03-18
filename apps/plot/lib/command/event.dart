import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/widget/icon.dart';
import 'command.dart';

class ArchiveEventCommand extends Command {
  ArchiveEventCommand(
    this.event,
  ) : super(
          title: 'Archive Event',
          icon: PlotIcon.delete,
        );

  final Event event;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context
        .read<ScheduleBloc>()
        .update(event.copyWith(deletedAt: Value(DateTime.now())));
    return null;
  }
}
