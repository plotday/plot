import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
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

    /// Whether to disable running the command on tap (just display the tile).
    this.noRun = false,

    /// Builder for optional widget displayed on the left, after the leading indicator.
    /// Receives hover and focus state to conditionally display content.
    this.leadingBuilder,

    /// Builder for optional widget displayed on the right.
    /// Receives hover and focus state to conditionally display content.
    this.trailingBuilder,

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

    /// Disable hover highlighting entirely (keyboard focus highlighting still works).
    this.noHoverHighlight = false,

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

    /// Builder for body that receives highlighted state
    this.bodyBuilder,
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

    /// Whether to show the keyboard shortcut (default: false).
    this.showShortcut = false,

    super.key,
  }) : subtitle = subtitle ?? command?.subtitle;

  final ListTileStyle style;
  final bool highlighted;
  final bool selected;
  final bool selectedBorder;
  final int indentLevel;
  final bool disableInternalHover;
  final bool noHoverHighlight;
  final Widget? details;
  final Command? command;
  final Command? doubleTapCommand;
  final Command? longPressCommand;
  final bool noRun;
  final Widget? Function(bool isHovered, bool hasFocus)? leadingBuilder;
  final Widget? Function(bool isHovered, bool hasFocus)? trailingBuilder;
  final String? title;
  final String? subtitle;
  final Widget? body;
  final Widget? Function(BuildContext context, bool highlighted)? bodyBuilder;
  final Widget? header;

  final IconData? icon;
  final bool centered;
  final EdgeInsetsGeometry? padding;
  final TextStyle? textStyle;

  final void Function(bool hovered)? onHover;
  final FocusNode? focusNode;
  final int? reorderableIndex;
  final bool showShortcut;

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

  bool get showDragBar =>
      !hasPhysicalKeyboard() && widget.reorderableIndex != null;

  @override
  Widget build(BuildContext context) {
    final child = MouseRegion(
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
        child: ReorderableDragStartListener(
          index: widget.reorderableIndex ?? 0,
          enabled: widget.reorderableIndex != null && !showDragBar,
          child: Container(
            decoration: BoxDecoration(
              color: widget.selected
                  ? context.theme.colors.primaryForeground
                  : _focusNode.hasFocus ||
                        (!widget.noHoverHighlight &&
                            !widget.disableInternalHover &&
                            _isHovered) ||
                        widget.highlighted
                  ? context.theme.plotColors.highlight
                  : null,
            ),
            padding: EdgeInsets.only(left: widget.indentLevel * 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: widget.leadingBuilder == null
                      ? widget.padding?.resolve(null).left ?? 16
                      : 0,
                ),

                ...[
                  if (widget.leadingBuilder != null)
                    widget.leadingBuilder!(_isHovered, _focusNode.hasFocus),
                ].whereType<Widget>(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    spacing: 8,
                    children: [
                      if (widget.icon != null || widget.command?.icon != null)
                        Icon(
                          widget.icon ?? widget.command?.icon,
                          size: 15,
                          color: context.theme.plotColors.muted,
                        ),
                      Expanded(
                        child: Padding(
                          padding:
                              (widget.padding?.resolve(null) ?? widgetPaddingSm)
                                  .copyWith(
                                    left: 0,
                                    right: 0,
                                    top: widget.style == .header ? 2 : null,
                                    bottom: widget.style == .header ? 2 : null,
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
                                  // Calculate highlighted state
                                  final isHighlighted =
                                      _focusNode.hasFocus ||
                                      _isHovered ||
                                      widget.highlighted;

                                  final commandBody =
                                      widget.bodyBuilder?.call(
                                        context,
                                        isHighlighted,
                                      ) ??
                                      widget.body ??
                                      (widget.title == null
                                          ? widget.command?.buildBody(context)
                                          : null);
                                  return commandBody != null
                                      ? Row(
                                          children: [
                                            Expanded(child: commandBody),
                                          ],
                                        )
                                      : Row(
                                          mainAxisAlignment: widget.centered
                                              ? MainAxisAlignment.center
                                              : MainAxisAlignment.start,
                                          spacing: 4,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                widget.title ??
                                                    widget.command?.title ??
                                                    'Untitled',
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: widget.centered
                                                    ? TextAlign.center
                                                    : TextAlign.start,
                                                style:
                                                    (widget.textStyle ??
                                                            (widget.style ==
                                                                    ListTileStyle
                                                                        .header
                                                                ? context
                                                                      .theme
                                                                      .typography
                                                                      .sm
                                                                : context
                                                                      .theme
                                                                      .typography
                                                                      .base))
                                                        .copyWith(
                                                          color: widget.selected
                                                              ? context
                                                                    .theme
                                                                    .colors
                                                                    .primary
                                                              : widget.style ==
                                                                    ListTileStyle
                                                                        .header
                                                              ? context
                                                                    .theme
                                                                    .plotColors
                                                                    .muted
                                                              : null,
                                                        ),
                                              ),
                                            ),
                                            if (widget.subtitle != null)
                                              Expanded(
                                                child: Text(
                                                  widget.subtitle!,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: context
                                                      .theme
                                                      .typography
                                                      .base
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
                              if (widget.details != null) widget.details!,
                            ],
                          ),
                        ),
                      ),
                      if (widget.showShortcut &&
                          widget.command?.shortcut != null &&
                          hasPhysicalKeyboard())
                        Text(
                          formatShortcut(widget.command?.shortcut),
                          style: context.theme.typography.base.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                ...[
                  if (widget.trailingBuilder != null)
                    widget.trailingBuilder!(_isHovered, _focusNode.hasFocus),
                ].whereType<Widget>(),
                // Drag bar at the end (outside main drag listener)
                if (showDragBar && widget.reorderableIndex != null)
                  GestureDetector(
                    // Prevent long press from propagating to parent (which opens command modal)
                    onLongPress: () {},
                    behavior: HitTestBehavior.opaque,
                    child: ReorderableDragStartListener(
                      index: widget.reorderableIndex!,
                      child: Padding(
                        // Larger padding for easier touch target (~44x44 logical pixels)
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          FontAwesomeIcons.gripDotsVertical,
                          size: 12,
                          color: context.theme.plotColors.muted,
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width:
                      (!(showDragBar && widget.reorderableIndex != null) &&
                          widget.trailingBuilder == null
                      ? widget.padding?.resolve(null).right ?? 16
                      : 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Only add GestureDetector if noRun is false and command exists
    if (!widget.noRun && widget.command != null) {
      return GestureDetector(
        onTap: () {
          log.info("Running command: ${widget.command?.title}");
          try {
            context.run(widget.command!);
          } catch (e, t) {
            log.warning("Action ${widget.command?.title} failed", e, t);
          }
        },
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
        child: child,
      );
    } else {
      return child;
    }
  }
}
