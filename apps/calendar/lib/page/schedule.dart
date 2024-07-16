import 'package:flutter/widgets.dart';

import 'package:plot/widget/schedule.dart';
import 'package:plot/widget/widget.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ScheduleWidget(
        scrollController: ScrollControllerContext.of(context),
      ),
    );
  }
}
