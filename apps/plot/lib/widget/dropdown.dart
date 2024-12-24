import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Dropdown extends StatelessWidget {
  final Widget child;
  final Widget dropdown;
  final OverlayPortalController controller;
  final GlobalKey _childKey = GlobalKey();

  Dropdown({
    required this.child,
    required this.dropdown,
    required this.controller,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: controller,
      overlayChildBuilder: (BuildContext context) {
        final RenderBox? renderBox =
            _childKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox?.hasSize != true) {
          return Container();
        }
        return Positioned(
          top: renderBox!.localToGlobal(Offset.zero).dy,
          left: renderBox.localToGlobal(Offset.zero).dx,
          width: renderBox.size.width,
          child: TapRegion(
            onTapOutside: (tap) {
              controller.hide();
            },
            child: PlatformBuilder(
              macOSBuilder: (_) => macos.MacosOverlayFilter(
                borderRadius: const BorderRadius.all(Radius.circular(7.0)),
                child: dropdown,
              ),
              builder: (_) => material.Material(
                elevation: 8,
                child: dropdown,
              ),
            ),
          ),
        );
      },
      child: Container(
        key: _childKey,
        child: child,
      ),
    );
  }
}
