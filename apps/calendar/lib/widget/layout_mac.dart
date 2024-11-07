import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/router.dart';
import 'activity_nav.dart';
import 'scroll_context.dart';
import 'package:plot/widget/global_menu.dart';

class MacLayout extends StatefulWidget {
  const MacLayout(this.left, this.main, this.right, {super.key});

  @override
  State<MacLayout> createState() {
    return MacLayoutState();
  }

  final Widget main;
  final Widget? right;
  final Widget left;
}

class MacLayoutState extends State<MacLayout> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) {
        return GlobalMenu(
            child: MacosWindow(
          child: MacosScaffold(
            toolBar: ToolBar(
              title: const ActivityNav(),
              actions: [
                ToolBarIconButton(
                  icon: const material.Icon(material.Icons.calendar_today),
                  label: 'Schedule',
                  showLabel: false,
                  onPressed: () {
                    HomeRoute.day(state.day).go(context);
                  },
                ),
              ],
            ),
            children: [
              ResizablePane(
                builder: (context, scrollController) => ScrollControllerContext(
                  controller: scrollController,
                  child: widget.left,
                ),
                startSize: 300,
                minSize: 300,
                maxSize: 400,
                resizableSide: ResizableSide.right,
              ),
              ResizablePane(
                builder: (context, scrollController) => ScrollControllerContext(
                  controller: scrollController,
                  child: widget.main,
                ),
                startSize: 300,
                minSize: 300,
                maxSize: 400,
                resizableSide: ResizableSide.right,
              ),
              if (widget.right != null)
                ContentArea(
                  builder: (context, scrollController) =>
                      ScrollControllerContext(
                    controller: scrollController,
                    child: widget.right!,
                  ),
                ),
            ],
          ),
        ));
      },
    );
  }
}
