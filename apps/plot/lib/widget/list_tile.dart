import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'animated_command_row.dart';
import 'logging.dart';

enum ListTileStyle { item, header }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary action run when the tile is tapped.
    this.command,

    /// The action to run when the tile is double-tapped.
    this.doubleTapCommand,

    /// The action to run when the tile is long-pressed.
    this.longPressCommand,

    /// Secondary actions visible on the right.
    this.trailingCommands = const [],

    /// Whether to animate reveal of trailing commands on hover/focus.
    /// When true, commands are hidden by default and slide in on hover/focus.
    this.revealTrailingCommands = false,

    /// Optional widget displayed at the far right (after trailingCommands).
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

    /// Optional text style override for the title.
    /// If not provided, uses sm for headers and base for items.
    this.textStyle,

    /// Index for reorderable list. If provided, enables drag on left portion only.
    this.reorderableIndex,

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
  final Command? longPressCommand;
  final List<Command> trailingCommands;
  final bool revealTrailingCommands;
  final Widget? trailing;
  final String? title;
  final String? subtitle;
  final Widget? body;
  final Widget? header;

  final IconData? icon;
  final bool centered;
  final EdgeInsetsGeometry? padding;
  final TextStyle? textStyle;

  final void Function(bool hovered)? onHover;
  final FocusNode? focusNode;
  final int? reorderableIndex;

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
    final bool isTouchDevice = !hasPhysicalKeyboard();
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
      onLongPress: widget.longPressCommand != null
          ? () {
              try {
                context.run(widget.longPressCommand!);
              } catch (e, t) {
                log.warning(
                  "Action ${widget.longPressCommand?.title} failed",
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
                  : widget.command != null &&
                        (_focusNode.hasFocus ||
                            (!widget.disableInternalHover && _isHovered) ||
                            widget.highlighted)
                  ? context.theme.plotColors.highlight
                  : null,
            ),
            padding:
                (widget.padding?.resolve(null) ?? widgetPaddingSm).copyWith(
                  left: isTouchDevice ? 0 : null,
                  top: 0,
                  bottom: 0,
                ) +
                EdgeInsets.only(left: widget.indentLevel * 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 4,
              children: [
                // Draggable portion (icon + content)
                ..._buildDraggableContent(context),
                // Non-draggable portion (shortcuts + commands + trailing)
                if (widget.command?.shortcut != null && hasPhysicalKeyboard())
                  Text(
                    formatShortcut(widget.command?.shortcut),
                    style: context.theme.typography.base.copyWith(
                      color: context.theme.plotColors.muted,
                    ),
                  ),
                if (widget.trailingCommands.isNotEmpty)
                  AnimatedCommandRow(
                    show:
                        !widget.revealTrailingCommands ||
                        _isHovered ||
                        _focusNode.hasFocus,
                    commands: widget.trailingCommands,
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDraggableContent(BuildContext context) {
    final bool isTouchDevice = !hasPhysicalKeyboard();

    // Build the icon widget if present
    final iconWidget = (widget.icon != null || widget.command?.icon != null)
        ? Icon(
            widget.icon ?? widget.command?.icon,
            size: 16,
            color: context.theme.plotColors.muted,
          )
        : null;

    // Build the main content widget
    final contentWidget = Expanded(
      child: Padding(
        padding: (widget.padding?.resolve(null) ?? widgetPaddingSm).copyWith(
          left: 0,
          right: 0,
        ),
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
                        spacing: 4,
                        children: [
                          Text(
                            widget.title ?? widget.command?.title ?? 'Untitled',
                            overflow: TextOverflow.ellipsis,
                            textAlign: widget.centered
                                ? TextAlign.center
                                : TextAlign.start,
                            style:
                                (widget.textStyle ??
                                        (widget.style == ListTileStyle.header
                                            ? context.theme.typography.sm
                                            : context.theme.typography.base))
                                    .copyWith(
                                      color: widget.selected
                                          ? context
                                                .theme
                                                .colors
                                                .primaryForeground
                                          : widget.style == ListTileStyle.header
                                          ? context.theme.plotColors.muted
                                          : null,
                                    ),
                          ),
                          if (widget.subtitle != null)
                            Expanded(
                              child: Text(
                                widget.subtitle!,
                                overflow: TextOverflow.ellipsis,
                                style: context.theme.typography.base.copyWith(
                                  color: context.theme.plotColors.muted,
                                ),
                              ),
                            ),
                        ],
                      );
              },
            ),
            if (widget.details != null) widget.details!,
          ],
        ),
      ),
    );

    // If not reorderable, return content as is
    if (widget.reorderableIndex == null) {
      return [if (iconWidget != null) iconWidget, contentWidget];
    }

    // For touch devices: show drag handle, only handle is draggable
    if (isTouchDevice) {
      final dragHandle = ReorderableDragStartListener(
        index: widget.reorderableIndex!,
        child: Icon(
          FontAwesomeIcons.gripDotsVertical,
          size: 8,
          color: context.theme.plotColors.muted,
        ),
      );

      return [dragHandle, if (iconWidget != null) iconWidget, contentWidget];
    }

    // For non-touch devices: entire content is draggable
    final draggableChild = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 8,
      children: [if (iconWidget != null) iconWidget, contentWidget],
    );

    final reorderableWidget = ReorderableDragStartListener(
      index: widget.reorderableIndex!,
      child: draggableChild,
    );

    return [Expanded(child: reorderableWidget)];
  }
}
