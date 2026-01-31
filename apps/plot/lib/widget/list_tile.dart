import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'logging.dart';
import 'spinner.dart';

/// Controller for programmatically triggering ListTile command execution
class ListTileController {
  Future<CommandReturn> Function()? _run;
  final Completer<void> _initCompleter = Completer<void>();

  /// Check if the controller is initialized (attached to a ListTile)
  bool get isInitialized => _initCompleter.isCompleted;

  /// Check if the controller is currently attached to a ListTile
  bool get isAttached => _run != null;

  Future<void> _waitForInit() async {
    if (!_initCompleter.isCompleted) {
      await _initCompleter.future;
    }
  }

  Future<CommandReturn> run() async {
    await _waitForInit();
    // Capture _run in local variable to avoid race condition
    final run = _run;
    if (run == null) {
      return const CommandSkipped();
    }
    return run();
  }

  void _attach(Future<CommandReturn> Function() run) {
    _run = run;
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
  }

  void _detach() {
    _run = null;
    // Note: completer stays completed - prevents issues with post-detach calls
  }
}

enum ListTileStyle { item, header, button }

class ListTile extends StatefulWidget {
  ListTile({
    /// The primary action run when the tile is tapped.
    this.command,

    /// The action to run when the tile is long-pressed.
    this.longPressCommand,

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

    /// Optional controller for programmatic command execution.
    /// Allows external code to trigger the run() method.
    this.controller,

    /// Optional callback when command completes with the result.
    /// Parent should handle the result and return true if handled.
    this.onRun,

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

    /// Whether to show a drag handle in the leading area (for reorder mode).
    this.showLeadingDragHandle = false,

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
  final Command? longPressCommand;
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
  final ListTileController? controller;
  final Future<bool> Function(BuildContext context, CommandReturn result)?
  onRun;
  final int? reorderableIndex;
  final bool showShortcut;
  final bool showLeadingDragHandle;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  FocusNode? _internalFocusNode;
  Offset? lastMousePosition;
  bool _isHovered = false;

  // Running state management
  bool _isRunning = false;
  Timer? _spinnerDelayTimer;
  bool _showSpinner = false;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode!;

  /// Expose run method for external triggers (e.g., Enter key in forms)
  Future<CommandReturn> run() async {
    if (_isRunning || widget.command == null) {
      return const CommandSkipped();
    }

    if (!mounted) {
      return const CommandSkipped();
    }

    setState(() {
      _isRunning = true;
      // Start 100ms delay before showing spinner
      _spinnerDelayTimer = Timer(const Duration(milliseconds: 100), () {
        if (mounted && _isRunning) {
          setState(() => _showSpinner = true);
        }
      });
    });

    try {
      // Call onRun callback if provided
      if (widget.onRun != null) {
        final result = await widget.command!.run(context);
        if (mounted) {
          await widget.onRun!(context, result);
        }
        return result;
      } else {
        return await context.run(widget.command!);
      }
    } catch (e, t) {
      log.warning("Action ${widget.command?.title} failed", e, t);
      rethrow;
    } finally {
      _spinnerDelayTimer?.cancel();
      if (mounted) {
        setState(() {
          _isRunning = false;
          _showSpinner = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Create internal focus node only if external one not provided
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode();
    }
    // Add listener to rebuild when focus changes
    _focusNode.addListener(_onFocusChange);
    // Attach controller if provided
    widget.controller?._attach(run);
  }

  void _onFocusChange() {
    setState(() {}); // Rebuild when focus changes
  }

  @override
  void dispose() {
    _spinnerDelayTimer?.cancel();
    _focusNode.removeListener(_onFocusChange);
    // Detach controller if provided
    widget.controller?._detach();
    // Only dispose internal focus node
    _internalFocusNode?.dispose();
    super.dispose();
  }

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
          enabled:
              widget.reorderableIndex != null &&
              hasPhysicalKeyboard() &&
              !widget.showLeadingDragHandle,
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

                // Leading area: either drag handle (in reorder mode) or custom leading builder
                if (widget.showLeadingDragHandle &&
                    widget.reorderableIndex != null)
                  ReorderableDragStartListener(
                    index: widget.reorderableIndex!,
                    child: Container(
                      color: Color(0x00000000),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Icon(
                        FontAwesomeIcons.gripDotsVertical,
                        size: context.theme.iconSizes.sm,
                        color: context.theme.plotColors.muted,
                      ),
                    ),
                  )
                else
                  ...[
                    if (widget.leadingBuilder != null)
                      widget.leadingBuilder!(_isHovered, _focusNode.hasFocus),
                  ].whereType<Widget>(),
                Expanded(
                  child: GestureDetector(
                    onTap: widget.command != null ? () => run() : null,
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
                    child: Container(
                      color: Color(0x00000000), // Transparent to capture taps
                      child: Builder(
                        builder: (context) {
                          // Build the icon widget
                          final iconWidget = () {
                            // If running with delay passed, show spinner
                            if (_showSpinner) {
                              return Spinner(
                                size: widget.style == ListTileStyle.header
                                    ? context.theme.iconSizes.sm
                                    : context.theme.iconSizes.base,
                                color: context.theme.plotColors.muted,
                              );
                            }

                            // Check for custom icon widget first (like Button does)
                            final customIcon = widget.command?.buildIcon(
                              context,
                            );
                            if (customIcon != null) return customIcon;

                            // Fall back to IconData icon
                            if (widget.icon != null ||
                                widget.command?.icon != null) {
                              return Icon(
                                widget.icon ?? widget.command?.icon,
                                size: widget.style == ListTileStyle.header
                                    ? context.theme.iconSizes.sm
                                    : context.theme.iconSizes.base,
                                color: context.theme.plotColors.muted,
                              );
                            }

                            return const SizedBox.shrink();
                          }();

                          // Only apply spacing when icon is present
                          final hasIcon = iconWidget is! SizedBox;

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            spacing: hasIcon ? 12 : 0,
                            children: [
                              if (hasIcon) iconWidget else iconWidget,
                              Expanded(
                                child: Padding(
                                  padding:
                                      (widget.padding?.resolve(null) ??
                                              widgetPaddingSm)
                                          .copyWith(
                                            left: 0,
                                            right: 0,
                                            top: widget.style == .header
                                                ? 2
                                                : null,
                                            bottom: widget.style == .header
                                                ? 2
                                                : null,
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
                                                  ? widget.command?.buildBody(
                                                      context,
                                                    )
                                                  : null);
                                          return commandBody != null
                                              ? Row(
                                                  children: [
                                                    Expanded(
                                                      child: commandBody,
                                                    ),
                                                  ],
                                                )
                                              : Text.rich(
                                                  TextSpan(
                                                    children: [
                                                      TextSpan(
                                                        text:
                                                            widget.title ??
                                                            widget
                                                                .command
                                                                ?.title ??
                                                            'Untitled',
                                                        style:
                                                            (widget.textStyle ??
                                                                    (widget.style ==
                                                                            ListTileStyle.header
                                                                        ? context
                                                                              .theme
                                                                              .typography
                                                                              .sm
                                                                        : context
                                                                              .theme
                                                                              .typography
                                                                              .base))
                                                                .copyWith(
                                                                  color:
                                                                      widget
                                                                          .selected
                                                                      ? context
                                                                            .theme
                                                                            .colors
                                                                            .primary
                                                                      : widget.style ==
                                                                            ListTileStyle.header
                                                                      ? context
                                                                            .theme
                                                                            .plotColors
                                                                            .muted
                                                                      : null,
                                                                  fontWeight:
                                                                      widget.style ==
                                                                            ListTileStyle.button
                                                                      ? FontWeight.bold
                                                                      : null,
                                                                ),
                                                      ),
                                                      if (widget.subtitle !=
                                                          null)
                                                        TextSpan(
                                                          text:
                                                              '  ${widget.subtitle!}',
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
                                                    ],
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textAlign: widget.centered
                                                      ? TextAlign.center
                                                      : TextAlign.start,
                                                );
                                        },
                                      ),
                                      if (widget.details != null)
                                        widget.details!,
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
                          );
                        },
                      ),
                    ),
                  ),
                ),
                ...[
                  if (widget.trailingBuilder != null)
                    widget.trailingBuilder!(_isHovered, _focusNode.hasFocus),
                ].whereType<Widget>(),
                SizedBox(
                  width: widget.trailingBuilder == null
                      ? widget.padding?.resolve(null).right ?? 16
                      : 0,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return child;
  }
}
