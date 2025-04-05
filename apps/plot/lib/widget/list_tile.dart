import 'package:flutter/services.dart';
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
  }) : style = ListTileStyle.header,
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
  }) : style = ListTileStyle.command,
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
  final _focusNode = FocusNode();

  Map<ShortcutActivator, Intent> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
  };

  Map<Type, Action<Intent>> get _actions => {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (ActivateIntent intent) {
        if (widget.command != null) {
          widget.command!.run(context);
        } else if (widget.commands.isNotEmpty) {
          widget.commands.first.run(context);
        }
        return null;
      },
    ),
  };

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
                } catch (e) {
                  print(e);
                }
              }
              : null,
      child: FocusableActionDetector(
        focusNode: _focusNode,
        actions: _actions,
        shortcuts: _shortcuts,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        onShowHoverHighlight: (hovered) {
          if (hovered) {
            _focusNode.requestFocus();
          }
        },
        child: Container(
          color: _focused ? context.colour.accentBackground : null,
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              if (widget.command?.icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FIcon.data(
                    widget.command!.icon!,
                    size: 12,
                    color: context.colour.muted,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
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
