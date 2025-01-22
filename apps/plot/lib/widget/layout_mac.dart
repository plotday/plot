import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/macos_window_utils.dart' as macos_win;
import 'package:macos_window_utils/macos/ns_window_button_type.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter_resizable_container/flutter_resizable_container.dart';
import 'package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container.dart';

import 'global_menu.dart';
import 'scaffold.dart';
import 'layout.dart';

class MacLayout extends StatelessWidget {
  static Future<void> init(BuildContext context) async {
    await const MacosWindowUtilsConfig(
      toolbarStyle: NSWindowToolbarStyle.unifiedCompact,
    ).apply();
    Layout.toolbarHeight =
        await macos_win.WindowManipulator.getTitlebarHeight();
    final lastWindowButtonPos =
        await macos_win.WindowManipulator.getStandardWindowButtonPosition(
      buttonType: NSWindowButtonType.zoomButton,
    );
    Layout.toolbarPadding = EdgeInsets.only(
      left: lastWindowButtonPos.right,
    );
  }

  const MacLayout(this.left, this.main, this.right, {this.header, super.key});

  final Widget main;
  final Widget? right;
  final Widget left;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    bool isDark =
        MediaQuery.of(context).platformBrightness == material.Brightness.dark;
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
          color: (HSLColor.fromColor(MacosColors.appleBlue))
              .withLightness(isDark ? 0.2 : 0.8)
              .withSaturation(isDark ? 0.7 : 1.0)
              .toColor()
              .withValues(alpha: 0.35),
          child: Scaffold(
            header: header,
            body: ResizableContainer(
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
                  child: Column(
                    children: [
                      Expanded(
                        child: ClipSmoothRect(
                          radius: SmoothBorderRadius(
                            cornerRadius: 16,
                            cornerSmoothing: 1,
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: MacosTheme.of(context).canvasColor,
                            ),
                            child: main,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16.0),
                    ],
                  ),
                ),
                if (right != null)
                  ResizableChild(
                    size: const ResizableSize.ratio(0.20),
                    minSize: 350,
                    maxSize: 500,
                    child: right!,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
