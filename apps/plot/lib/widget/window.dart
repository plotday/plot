import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/macos_window_utils.dart' as macos_win;
import 'package:macos_window_utils/macos/ns_window_button_type.dart';
import 'package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container.dart';
import 'package:platform_builder/platform_builder.dart';

class Window extends StatelessWidget {
  static late final double toolbarHeight;
  static late final EdgeInsetsGeometry toolbarPadding;

  static Future<void> init() async {
    if (Platform.instance.isMacOS) {
      await const MacosWindowUtilsConfig(
        toolbarStyle: NSWindowToolbarStyle.unifiedCompact,
      ).apply();
      toolbarHeight = await macos_win.WindowManipulator.getTitlebarHeight();
      final lastWindowButtonPos =
          await macos_win.WindowManipulator.getStandardWindowButtonPosition(
        buttonType: NSWindowButtonType.zoomButton,
      );
      toolbarPadding = EdgeInsets.only(
        left: lastWindowButtonPos.right,
      );
    } else {
      toolbarHeight = 32.0;
      toolbarPadding = const EdgeInsets.all(0);
    }
  }

  const Window({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    bool isDark =
        MediaQuery.of(context).platformBrightness == material.Brightness.dark;
    return PlatformBuilder(
      macOSBuilder: (_) => VisualEffectSubviewContainer(
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
          child: child,
        ),
      ),
      builder: (_) => child,
    );
  }
}
