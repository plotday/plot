import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

typedef OverlayVisibilityChangedCallback = void Function(bool isShowing);

class DropdownController extends OverlayPortalController {
  DropdownController();

  final _listeners = <OverlayVisibilityChangedCallback>[];

  void addListener(OverlayVisibilityChangedCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(OverlayVisibilityChangedCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener(super.isShowing);
    }
  }

  @override
  void hide() {
    super.hide();
    _notifyListeners();
  }

  @override
  void show() {
    super.show();
    _notifyListeners();
  }
}

class Dropdown extends StatefulWidget {
  final Widget child;
  final Widget dropdown;
  final DropdownController controller;
  final FocusNode? focusNode;

  const Dropdown({
    required this.child,
    required this.dropdown,
    required this.controller,
    this.focusNode,
    super.key,
  });

  @override
  DropdownState createState() => DropdownState();
}

class DropdownState extends State<Dropdown> {
  final GlobalKey _childKey = GlobalKey();
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  Size _childSize = Size.zero;
  Offset _childOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_getChildSize);
    widget.controller.addListener(_handleShowHide);
  }

  void _handleShowHide(bool isShowing) {
    if (isShowing) {
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    widget.controller.removeListener(_handleShowHide);
    super.dispose();
  }

  void _getChildSize(_) {
    final RenderBox? renderBox =
        _childKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      setState(() {
        _childSize = renderBox.size;
        _childOffset = renderBox.localToGlobal(Offset.zero);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.controller.hide();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: OverlayPortal(
        controller: widget.controller,
        overlayChildBuilder: (BuildContext context) {
          return Positioned(
            top: _childOffset.dy,
            left: _childOffset.dx,
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
      ),
    );
  }
}
