import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'button.dart';
import 'colour_scheme.dart';
import 'theme.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary command run when the tile is tapped.
    this.command,

    /// Secondary commands visible on the left.
    this.leadingCommand,

    /// Secondary commands visible on the right.
    this.trailingCommands = const [],

    /// Commands revealed on hover or long press.
    this.hiddenCommands = const [],

    /// Extra details shown below the title.
    this.details,

    /// Highlight the tile (often when unread).
    this.highlighted = false,
    this.style = ListTileStyle.item,

    /// Override the command title
    String? title,

    /// Override the body
    this.body,

    super.key,
  }) : title = title ?? command?.title ?? '';

  final ListTileStyle style;
  final bool highlighted;
  final Widget? details;
  final Command? command;
  final Command? leadingCommand;
  final List<Command> trailingCommands;
  final List<Command> hiddenCommands;
  final String title;
  final Widget? body;

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
        } else if (widget.trailingCommands.isNotEmpty) {
          widget.trailingCommands.first.run(context);
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
          color: _focused ? context.colour.highlight : null,
          padding: EdgeInsets.symmetric(
            horizontal: widgetPadding.horizontal / 2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.leadingCommand != null)
                Button.icon(widget.leadingCommand!),
              if (widget.leadingCommand == null &&
                  (widget.command?.statusIcon.or(widget.command?.icon)) != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FIcon.data(
                    (widget.command!.statusIcon.or(widget.command!.icon))!,
                    size: 12,
                    color: context.colour.muted,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: widgetPadding.vertical / 2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      widget.body ??
                          Row(
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
                              if (widget.command?.subtitle != null)
                                Text(
                                  '  ${widget.command!.subtitle!}',
                                  overflow: TextOverflow.ellipsis,
                                  style: context.theme.typography.xs.copyWith(
                                    color: context.colour.muted,
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
    );
  }
}
