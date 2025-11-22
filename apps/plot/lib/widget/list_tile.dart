import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'button.dart';
import 'logging.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary action run when the tile is tapped.
    this.command,

    /// The action to run when the tile is double-tapped.
    this.doubleTapCommand,

    /// Secondary actions visible on the right.
    this.trailingCommands = const [],

    /// Optional widget displayed at the far right (before trailingCommands).
    this.trailing,

    /// Extra details shown below the title.
    this.details,

    this.style = ListTileStyle.item,

    /// Whether this tile should show a highlight (for hover or keyboard selection).
    /// Deprecated: Use focusNode instead for keyboard navigation.
    this.highlighted = false,

    /// Whether this tile is selected (shows accent background).
    this.selected = false,

    /// Whether to show the border when selected (default: true).
    this.selectedBorder = true,

    /// Indentation level for nested items.
    this.indentLevel = 0,

    /// Disable internal hover highlighting (for external hover management).
    this.disableInternalHover = false,

    this.onHover,

    /// Optional external FocusNode for managing keyboard focus.
    /// If provided, this node will be used for focus management.
    /// If null, an internal FocusNode will be created.
    this.focusNode,

    /// Override the action title
    this.title,

    /// Display beside the title
    String? subtitle,

    /// Override the body
    this.body,
    this.header,
    this.icon,

    /// Whether to center the title text.
    this.centered = false,

    /// Custom padding for the tile.
    this.padding,

    super.key,
  }) : subtitle = subtitle ?? command?.subtitle;

  final ListTileStyle style;
  final bool highlighted;
  final bool selected;
  final bool selectedBorder;
  final int indentLevel;
  final bool disableInternalHover;
  final Widget? details;
  final Command? command;
  final Command? doubleTapCommand;
  final List<Command> trailingCommands;
  final Widget? trailing;
  final String? title;
  final String? subtitle;
  final Widget? body;
  final Widget? header;

  final IconData? icon;
  final bool centered;
  final EdgeInsetsGeometry? padding;

  final void Function(bool hovered)? onHover;
  final FocusNode? focusNode;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  FocusNode? _internalFocusNode;
  Offset? lastMousePosition;
  bool _isHovered = false;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode!;

  @override
  void initState() {
    super.initState();
    // Create internal focus node only if external one not provided
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode();
    }
    // Add listener to rebuild when focus changes
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() {}); // Rebuild when focus changes
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    // Only dispose internal focus node
    _internalFocusNode?.dispose();
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
                log.warning("Action ${widget.command?.title} failed", e, t);
              }
            }
          : null,
      onDoubleTap: widget.doubleTapCommand != null
          ? () {
              try {
                context.run(widget.doubleTapCommand!);
              } catch (e, t) {
                log.warning(
                  "Action ${widget.doubleTapCommand?.title} failed",
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
              borderRadius: tileBorderRadius,
              color: widget.selected
                  ? context.theme.colors.primary
                  : _focusNode.hasFocus ||
                        (!widget.disableInternalHover && _isHovered) ||
                        widget.highlighted
                  ? context.theme.plotColors.highlight
                  : null,
            ),
            padding:
                widget.padding ??
                widgetPaddingSm.copyWith(
                  left: widgetPaddingSm.left + (widget.indentLevel * 16.0),
                ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 10,
              children: [
                if (widget.icon != null || widget.command?.icon != null)
                  Icon(
                    widget.icon ?? widget.command?.icon,
                    size: 16,
                    color: context.theme.plotColors.muted,
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: widget.centered
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      if (widget.header != null) widget.header!,
                      Builder(
                        builder: (context) {
                          final commandBody =
                              widget.body ??
                              (widget.title == null
                                  ? widget.command?.buildBody(context)
                                  : null);
                          return commandBody != null
                              ? Row(children: [Expanded(child: commandBody)])
                              : Row(
                                  mainAxisAlignment: widget.centered
                                      ? MainAxisAlignment.center
                                      : MainAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.title ??
                                          widget.command?.title ??
                                          'Untitled',
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: widget.centered
                                          ? TextAlign.center
                                          : TextAlign.start,
                                      style: context.theme.typography.base
                                          .copyWith(
                                            color: widget.selected
                                                ? context
                                                      .theme
                                                      .colors
                                                      .primaryForeground
                                                : widget.style ==
                                                      ListTileStyle.header
                                                ? context.theme.plotColors.muted
                                                : context
                                                      .theme
                                                      .colors
                                                      .foreground,
                                          ),
                                    ),
                                    if (widget.subtitle != null)
                                      Expanded(
                                        child: Text(
                                          widget.subtitle!,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.theme.typography.base
                                              .copyWith(
                                                color: context
                                                    .theme
                                                    .plotColors
                                                    .muted,
                                              ),
                                        ),
                                      ),
                                  ],
                                );
                        },
                      ),
                      if (widget.command?.description != null)
                        Text(widget.command!.description!),
                      if (widget.details != null) widget.details!,
                    ],
                  ),
                ),
                if (widget.command?.shortcut != null && hasPhysicalKeyboard())
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      formatShortcut(widget.command?.shortcut),
                      style: context.theme.typography.base.copyWith(
                        color: context.theme.plotColors.muted,
                      ),
                    ),
                  ),
                if (widget.trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: widget.trailing!,
                  ),
                ...widget.trailingCommands.asMap().entries.map((entry) {
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
