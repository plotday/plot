import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';

import 'package:plot/router.dart';
import 'command.dart';
import 'package:plot/widget/icon.dart';

class ShowSchedule extends Command {
  ShowSchedule() : super(title: 'View Schedule', icon: PlotIcon.today);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push<void>(const ScheduleRoute());
    return null;
  }
}
