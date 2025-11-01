import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'theme.dart';
import 'button.dart';
import 'colour_scheme.dart';
import 'logging.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary command run when the tile is tapped.
    this.command,

    /// The command to run when the tile is double-tapped.
    this.doubleTapCommand,

    /// Secondary commands visible on the right.
    this.trailingCommands = const [],

    /// Extra details shown below the title.
    this.details,

    this.style = ListTileStyle.item,

    this.selected = false,
    this.onHover,

    /// Override the command title
    String? title,

    /// Override the body
    this.body,
    this.header,
    this.icon,

    super.key,
  }) : title = title ?? command?.title ?? '';

  final ListTileStyle style;
  final bool selected;
  final Widget? details;
  final Command? command;
  final Command? doubleTapCommand;
  final List<Command> trailingCommands;
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
      onTap: widget.command != null
          ? () {
              log.info("Running command: ${widget.command?.title}");
              try {
                context.run(widget.command!);
              } catch (e, t) {
                log.warning("Command ${widget.command?.title} failed", e, t);
              }
            }
          : null,
      onDoubleTap: widget.doubleTapCommand != null
          ? () {
              try {
                context.run(widget.doubleTapCommand!);
              } catch (e, t) {
                log.warning(
                  "Command ${widget.doubleTapCommand?.title} failed",
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
            color: widget.selected
                ? context.colour.accentBackground
                : _isHovered
                ? context.colour.highlight
                : null,
            padding: widgetPaddingSm,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 10,
              children: [
                if (widget.icon != null || widget.command?.icon != null)
                  Icon(
                    widget.icon ?? widget.command?.icon,
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
                                      color:
                                          widget.style == ListTileStyle.header
                                          ? context.colour.muted
                                          : context.colour.foreground,
                                    ),
                                  ),
                                ),
                                if (widget.command?.subtitle != null)
                                  Flexible(
                                    child: Text(
                                      '  ${widget.command!.subtitle!}',
                                      overflow: TextOverflow.ellipsis,
                                      style: context.theme.typography.sm
                                          .copyWith(
                                            color: context.colour.muted,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                      if (widget.command?.description != null)
                        Text(widget.command!.description!),
                      if (widget.details != null) widget.details!,
                    ],
                  ),
                ),
                ...widget.trailingCommands.asMap().entries.map((entry) {
                  final key = ValueKey(Object.hash(entry.value.hashCode, entry.key));
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
