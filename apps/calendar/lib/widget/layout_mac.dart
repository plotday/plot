import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/router.dart';
import 'context_nav.dart';
import 'scroll_context.dart';

class MacLayout extends StatefulWidget {
  const MacLayout(this.drawer, this.primary, this.secondary, {super.key});

  @override
  State<MacLayout> createState() {
    return MacLayoutState();
  }

  final Widget primary;
  final Widget? secondary;
  final Widget drawer;
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
        return MacosWindow(
          child: MacosScaffold(
            toolBar: ToolBar(
              title: const ContextNav(),
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
                  child: widget.drawer,
                ),
                startSize: 300,
                minSize: 300,
                maxSize: 400,
                resizableSide: ResizableSide.right,
              ),
              ResizablePane(
                builder: (context, scrollController) => ScrollControllerContext(
                  controller: scrollController,
                  child: widget.primary,
                ),
                startSize: 300,
                minSize: 300,
                maxSize: 400,
                resizableSide: ResizableSide.right,
              ),
              if (widget.secondary != null)
                ContentArea(
                  builder: (context, scrollController) =>
                      ScrollControllerContext(
                    controller: scrollController,
                    child: widget.secondary!,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
