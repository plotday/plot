import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'button.dart';
import 'colour_scheme.dart';
import 'theme.dart';
import 'logging.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary command run when the tile is tapped.
    this.command,

    /// The command to run when the tile is double-tapped.
    this.doubleTapCommand,

    /// Secondary commands visible on the left.
    this.leadingCommand,

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

    super.key,
  }) : title = title ?? command?.title ?? '';

  final ListTileStyle style;
  final bool selected;
  final Widget? details;
  final Command? command;
  final Command? doubleTapCommand;
  final Command? leadingCommand;
  final List<Command> trailingCommands;
  final String title;
  final Widget? body;
  final Widget? header;
  final void Function()? onHover;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  final _focusNode = FocusNode();
  Offset? lastMousePosition;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap:
          widget.command != null
              ? () {
                try {
                  widget.command!.run(context);
                } catch (e, t) {
                  log.warning("Command ${widget.command?.title} failed", e, t);
                }
              }
              : null,
      onDoubleTap:
          widget.doubleTapCommand != null
              ? () {
                try {
                  widget.doubleTapCommand!.run(context);
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
        onHover: (PointerHoverEvent event) {
          if (event.position != lastMousePosition) {
            widget.onHover?.call();
            lastMousePosition = event.position;
          }
        },
        child: FocusableActionDetector(
          focusNode: _focusNode,
          // onShowFocusHighlight: (focused) => setState(() => _focused = focused),
          // onShowHoverHighlight: (hovered) {
          //   if (!hovered) setState(() => _focused = false);
          // },
          child: Container(
            color: widget.selected ? context.colour.highlight : null,
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              spacing: 4,
              children: [
                if (widget.leadingCommand != null)
                  Button.icon(widget.leadingCommand!),
                if (widget.leadingCommand == null &&
                    widget.body == null &&
                    (widget.command?.statusIcon.or(widget.command?.icon)) !=
                        null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Icon(
                      (widget.command!.statusIcon.or(widget.command!.icon))!,
                      size: 12,
                      color: context.colour.muted,
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        if (widget.header != null) widget.header!,
                        widget.body ??
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.style == ListTileStyle.header
                                        ? widget.title.toUpperCase()
                                        : widget.title,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.theme.typography.xs.copyWith(
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
                                      style: context.theme.typography.xs
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
                ),
                ...widget.trailingCommands.map((c) => Button.icon(c)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
