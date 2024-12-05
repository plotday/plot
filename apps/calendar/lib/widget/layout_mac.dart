import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter_resizable_container/flutter_resizable_container.dart';

import 'package:plot/state/schedule.dart';
import 'scroll_context.dart';
import 'scaffold.dart';
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
            child: WallpaperTintedArea(
              backgroundColor: MacosColors.appleBlue,
              child: ResizableContainer(
                direction: Axis.horizontal,
                divider: const ResizableDivider(
                  color: MacosColors.transparent,
                  thickness: 4.0,
                ),
                children: [
                  ResizableChild(
                    size: const ResizableSize.ratio(0.20),
                    minSize: 200,
                    maxSize: 400,
                    child: widget.left,
                  ),
                  ResizableChild(
                    child: Scaffold(
                      title: const Text("Plot"),
                      body: Column(
                        children: [
                          Expanded(
                            child: ClipSmoothRect(
                              radius: SmoothBorderRadius(
                                cornerRadius: 16,
                                cornerSmoothing: 1,
                              ),
                              child: Container(
                                decoration: const BoxDecoration(
                                    color: MacosColors.windowBackgroundColor),
                                child: widget.main,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16.0),
                        ],
                      ),
                    ),
                  ),
                  if (widget.right != null)
                    ResizableChild(
                      size: const ResizableSize.ratio(0.20),
                      minSize: 200,
                      maxSize: 400,
                      child: widget.right!,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
