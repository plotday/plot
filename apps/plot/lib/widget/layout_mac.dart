import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter_resizable_container/flutter_resizable_container.dart';
import 'package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container.dart';

import 'package:plot/page/widget/global_menu.dart';
import 'scaffold.dart';

class MacLayout extends StatelessWidget {
  const MacLayout(this.left, this.main, this.right, {this.title, super.key});

  final Widget main;
  final Widget? right;
  final Widget left;
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    return GlobalMenu(
      child: VisualEffectSubviewContainer(
        alphaValue: 1,
        material: NSVisualEffectViewMaterial.underWindowBackground,
        state: NSVisualEffectViewState.followsWindowActiveState,
        // Due to the fact that visual effect subviews cannot be updated while the
        // window is being resized, doing so can cause visual artifacts. To hide
        // those artifacts, the TransparentMacOSBottomBar widget adds a large
        // negative margin to the visual effect subview.
        padding: const EdgeInsets.all(-2000.0),
        child: Container(
          color: MacosColors.appleBlue.withAlpha(96),
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
                child: left,
              ),
              ResizableChild(
                child: Scaffold(
                  title: title,
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
                            child: main,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16.0),
                    ],
                  ),
                ),
              ),
              if (right != null)
                ResizableChild(
                  size: const ResizableSize.ratio(0.20),
                  minSize: 200,
                  maxSize: 400,
                  child: right!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
