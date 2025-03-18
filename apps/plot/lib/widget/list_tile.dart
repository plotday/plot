import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'button.dart';
import 'colour_scheme.dart';

enum ListTileStyle { command, header }

class ListTile extends StatefulWidget {
  const ListTile.header({
    required this.title,

    /// Secondary commands visible on the right.
    this.commands = const [],

    /// Commands revealed on hover or long press.
    this.hiddenCommands = const [],
    super.key,
  })  : style = ListTileStyle.command,
        command = null,
        details = null,
        highlighted = false;

  ListTile.command(
    Command command, {
    /// The primary command run when the tile is tapped.
    /// Secondary commands visible on the right.
    this.commands = const [],

    /// Commands revealed on hover or long press.
    this.hiddenCommands = const [],

    /// Extra details shown below the title.
    this.details,

    /// Highlight the tile (often when unread).
    this.highlighted = false,
    super.key,
  })  : style = ListTileStyle.header,
        command = command,
        title = command.title;

  final ListTileStyle style;
  final bool highlighted;
  final Widget? details;
  final Command? command;
  final List<Command> commands;
  final List<Command> hiddenCommands;
  final String title;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.command != null ? () => widget.command!.run(context) : null,
      child: FocusableActionDetector(
        // actions: _actionMap,
        // shortcuts: _shortcutMap,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        onShowHoverHighlight: (hovered) {
          if (hovered) {
            FocusScope.of(context).requestFocus(FocusNode());
          }
        },
        child: Container(
          color: _focused ? context.colour.background : null,
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              if (widget.command?.icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FIcon.data(widget.command!.icon!, size: 12),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.xs.copyWith(
                        color: widget.highlighted
                            ? null
                            : context.theme.colorScheme.mutedForeground,
                      ),
                    ),
                    if (widget.command?.description != null)
                      Text(widget.command!.description!),
                    if (widget.details != null) widget.details!,
                  ],
                ),
              ),
              ...widget.commands.map((c) => Button.icon(c)),
            ],
          ),
        ),
      ),
    );
  }
}
