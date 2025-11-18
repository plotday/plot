import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:forui/forui.dart';

import 'package:plot/action/action.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'theme.dart';
import 'button.dart';
import 'colour_scheme.dart';
import 'logging.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary action run when the tile is tapped.
    this.action,

    /// The action to run when the tile is double-tapped.
    this.doubleTapAction,

    /// Secondary actions visible on the right.
    this.trailingActions = const [],

    /// Extra details shown below the title.
    this.details,

    this.style = ListTileStyle.item,

    /// Whether this tile should show a highlight (for hover or keyboard selection).
    this.highlighted = false,

    /// Whether this tile is selected (shows left border and primary color).
    this.selected = false,

    /// Indentation level for nested items.
    this.indentLevel = 0,

    /// Disable internal hover highlighting (for external hover management).
    this.disableInternalHover = false,

    this.onHover,

    /// Override the action title
    String? title,

    /// Override the body
    this.body,
    this.header,
    this.icon,

    super.key,
  }) : title = title ?? action?.title ?? '';

  final ListTileStyle style;
  final bool highlighted;
  final bool selected;
  final int indentLevel;
  final bool disableInternalHover;
  final Widget? details;
  final Action? action;
  final Action? doubleTapAction;
  final List<Action> trailingActions;
  final String title;
  final Widget? body;
  final Widget? header;

  final IconData? icon;

  final void Function(bool hovered)? onHover;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  final _focusNode = FocusNode();
  Offset? lastMousePosition;
  bool _isHovered = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.action != null
          ? () {
              log.info("Running action: ${widget.action?.title}");
              try {
                context.run(widget.action!);
              } catch (e, t) {
                log.warning("Action ${widget.action?.title} failed", e, t);
              }
            }
          : null,
      onDoubleTap: widget.doubleTapAction != null
          ? () {
              try {
                context.run(widget.doubleTapAction!);
              } catch (e, t) {
                log.warning(
                  "Action ${widget.doubleTapAction?.title} failed",
                  e,
                  t,
                );
              }
            }
          : null,
      child: MouseRegion(
        onEnter: (_) {
          setState(() {
            _isHovered = true;
          });
          widget.onHover?.call(true);
        },
        onExit: (_) {
          setState(() {
            _isHovered = false;
          });
          widget.onHover?.call(false);
        },
        onHover: (PointerHoverEvent event) {
          if (event.position != lastMousePosition) {
            lastMousePosition = event.position;
          }
        },
        child: FocusableActionDetector(
          focusNode: _focusNode,
          onShowFocusHighlight: (focused) => widget.onHover?.call(focused),
          onShowHoverHighlight: (hovered) => widget.onHover?.call(hovered),
          child: Container(
            decoration: BoxDecoration(
              color: widget.highlighted ||
                     (!widget.disableInternalHover && _isHovered) ||
                     _focusNode.hasFocus
                  ? context.colour.highlight
                  : null,
              border: widget.selected
                  ? Border(
                      left: BorderSide(
                        color: context.colour.accent,
                        width: 3,
                      ),
                    )
                  : null,
            ),
            padding: widgetPaddingSm.copyWith(
              left: widgetPaddingSm.left + (widget.indentLevel * 16.0) - (widget.selected ? 3.0 : 0.0),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 10,
              children: [
                if (widget.icon != null || widget.action?.icon != null)
                  Icon(
                    widget.icon ?? widget.action?.icon,
                    size: 16,
                    color: context.colour.muted,
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      if (widget.header != null) widget.header!,
                      widget.body != null
                          ? Row(children: [Expanded(child: widget.body!)])
                          : Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.style == ListTileStyle.header
                                        ? widget.title.toUpperCase()
                                        : widget.title,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.theme.typography.sm.copyWith(
                                      color: widget.selected
                                          ? context.colour.accent
                                          : widget.style == ListTileStyle.header
                                              ? context.colour.muted
                                              : context.colour.foreground,
                                    ),
                                  ),
                                ),
                                if (widget.action?.subtitle != null)
                                  Flexible(
                                    child: Text(
                                      '  ${widget.action!.subtitle!}',
                                      overflow: TextOverflow.ellipsis,
                                      style: context.theme.typography.sm
                                          .copyWith(
                                            color: context.colour.muted,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                      if (widget.action?.description != null)
                        Text(widget.action!.description!),
                      if (widget.details != null) widget.details!,
                    ],
                  ),
                ),
                if (widget.action?.shortcut != null && hasPhysicalKeyboard())
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      formatShortcut(widget.action?.shortcut),
                      style: context.theme.typography.sm.copyWith(
                        color: context.colour.muted,
                      ),
                    ),
                  ),
                ...widget.trailingActions.asMap().entries.map((entry) {
                  final key = ValueKey(
                    Object.hash(entry.value.hashCode, entry.key),
                  );
                  return Button.icon(entry.value, key: key);
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
