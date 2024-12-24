import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Dropdown extends StatefulWidget {
  final Widget child;
  final Widget dropdown;
  final OverlayPortalController controller;

  const Dropdown({
    required this.child,
    required this.dropdown,
    required this.controller,
    super.key,
  });

  @override
  DropdownState createState() => DropdownState();
}

class DropdownState extends State<Dropdown> {
  final GlobalKey _childKey = GlobalKey();
  Size _childSize = Size.zero; // State variable for storing child size

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_getChildSize);
  }

  void _getChildSize(_) {
    final RenderBox? renderBox =
        _childKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      setState(() {
        _childSize = renderBox.size;
      });
      print('Child size: $_childSize'); // Debug print
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: widget.controller,
      overlayChildBuilder: (BuildContext context) {
        final RenderBox? renderBox =
            _childKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox?.hasSize != true) {
          return Container();
        }
        return Positioned(
          top: renderBox!.localToGlobal(Offset.zero).dy,
          left: renderBox.localToGlobal(Offset.zero).dx,
          width: _childSize.width,
          child: TapRegion(
            onTapOutside: (tap) {
              widget.controller.hide();
            },
            child: PlatformBuilder(
              macOSBuilder: (_) => macos.MacosOverlayFilter(
                borderRadius: const BorderRadius.all(Radius.circular(7.0)),
                child: widget.dropdown,
              ),
              builder: (_) => material.Material(
                elevation: 8,
                child: widget.dropdown,
              ),
            ),
          ),
        );
      },
      child: Container(
        key: _childKey,
        child: widget.child,
      ),
    );
  }
}
