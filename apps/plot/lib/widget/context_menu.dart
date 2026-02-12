import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:plot/widget/widget.dart';

/// A context menu that appears at the cursor position on right-click.
///
/// Uses [OverlayPortal] to position a menu overlay at the cursor's global
/// coordinates. Styled with forui's [FPopoverMenuStyle] for consistency.
///
/// Uses [Listener] instead of [GestureDetector] for right-click detection
/// so events are captured before child widgets (e.g. SuperReader) can
/// consume them in the gesture arena.
class ContextMenu extends StatefulWidget {
  const ContextMenu({
    required this.items,
    required this.child,
    super.key,
  });

  /// Builder that returns the menu items. Called when the menu is shown.
  final List<FItem> Function() items;

  /// The child widget that responds to right-click.
  final Widget child;

  @override
  State<ContextMenu> createState() => _ContextMenuState();
}

class _ContextMenuState extends State<ContextMenu> {
  final _controller = OverlayPortalController();
  final _focusNode = FocusNode();
  Offset _cursorPosition = Offset.zero;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _show(Offset globalPosition) {
    setState(() {
      _cursorPosition = globalPosition;
    });
    if (!_controller.isShowing) {
      _controller.show();
    }
    _focusNode.requestFocus();
  }

  void _hide() {
    if (_controller.isShowing) {
      _controller.hide();
    }
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final style = context.theme.popoverMenuStyle;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _hide();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) {
          // Convert global cursor position to the Overlay's local coordinate
          // space. OverlayPortal may render into a nested Overlay (e.g. a
          // panel) whose origin is not (0,0) in screen coordinates.
          final overlayBox =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          final localCursor = overlayBox.globalToLocal(_cursorPosition);
          final overlaySize = overlayBox.size;

          return CustomSingleChildLayout(
            delegate: _ContextMenuLayoutDelegate(
              cursorPosition: localCursor,
              viewSize: overlaySize,
            ),
            child: TapRegion(
              onTapOutside: (_) => _hide(),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: style.maxWidth),
                child: DecoratedBox(
                  decoration: style.decoration,
                  child: FInheritedItemData(
                    child: FItemGroup.merge(
                      style: style.itemGroupStyle,
                      divider: FItemDivider.full,
                      children: [
                        FItemGroup(children: widget.items()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton) {
              _show(event.position);
            }
          },
          behavior: HitTestBehavior.translucent,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Positions the context menu at the cursor, adjusting to keep it on-screen.
class _ContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _ContextMenuLayoutDelegate({
    required this.cursorPosition,
    required this.viewSize,
  });

  final Offset cursorPosition;
  final Size viewSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(viewSize);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = cursorPosition.dx;
    double y = cursorPosition.dy;

    // Flip left if menu would overflow right edge
    if (x + childSize.width > viewSize.width) {
      x = x - childSize.width;
    }

    // Flip up if menu would overflow bottom edge
    if (y + childSize.height > viewSize.height) {
      y = y - childSize.height;
    }

    // Clamp to viewport
    x = x.clamp(0, (viewSize.width - childSize.width).clamp(0, double.infinity));
    y = y.clamp(0, (viewSize.height - childSize.height).clamp(0, double.infinity));

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_ContextMenuLayoutDelegate oldDelegate) {
    return cursorPosition != oldDelegate.cursorPosition ||
        viewSize != oldDelegate.viewSize;
  }
}
