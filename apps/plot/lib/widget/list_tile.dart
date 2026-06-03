import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/time.dart';
import 'package:plot/style/spacing.dart';
import 'package:prism_flutter/prism_flutter.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'logging.dart';
import 'spinner.dart';

/// Controller for programmatically triggering ListTile command execution
class ListTileController {
  Future<CommandReturn> Function()? _run;
  Object? _owner;
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

  void _attach(Future<CommandReturn> Function() run, Object owner) {
    _run = run;
    _owner = owner;
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
  }

  /// Only detach if the caller is the current owner. This prevents a stale
  /// element's dispose from clearing a controller that was already re-attached
  /// to a different element (e.g. when ListView.builder reuses elements and the
  /// same controller moves from position N to position 0).
  void _detach(Object owner) {
    if (_owner == owner) {
      _run = null;
      _owner = null;
    }
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

    /// Skip the full-row background color (for tiles that manage their own highlight).
    this.noBackground = false,

    /// Overrides the default highlight background color.
    this.highlightColor,

    /// Overrides the default selected background color.
    this.selectedColor,
    this.selectedBorderColor,

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

    /// Border radius for the background decoration.
    this.borderRadius,

    /// Optional text style override for the title.
    /// If not provided, uses sm for headers and base for items.
    this.textStyle,

    /// Index for reorderable list. If provided, enables drag on left portion only.
    this.reorderableIndex,

    /// Cross-axis alignment for the leading/body/trailing row.
    this.crossAxisAlignment = CrossAxisAlignment.center,

    /// Whether to show the keyboard shortcut (default: false).
    this.showShortcut = false,

    /// When true, only the icon is shown (centered) and the title appears as a tooltip.
    this.iconOnly = false,

    /// When true, text and icon use muted color by default and foreground on hover.
    this.muted = false,

    /// Optional tap callback that overrides the command's tap behavior.
    this.onTap,

    super.key,
  }) : subtitle = subtitle ?? command?.subtitle;

  final ListTileStyle style;
  final bool highlighted;
  final bool selected;
  final bool selectedBorder;
  final int indentLevel;
  final bool disableInternalHover;
  final bool noHoverHighlight;
  final bool noBackground;
  final Color? highlightColor;
  final Color? selectedColor;

  /// When non-null, the tile reserves a constant 1px border that paints this
  /// colour while selected and transparent otherwise — so selection never
  /// shifts content. For rounded tiles (non-null [borderRadius]) this is the
  /// only way the selection ring is drawn; rounded tiles with a null
  /// [selectedBorderColor] keep their borderless behaviour.
  final Color? selectedBorderColor;
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
  final BorderRadius? borderRadius;
  final TextStyle? textStyle;

  final void Function(bool hovered)? onHover;
  final FocusNode? focusNode;
  final ListTileController? controller;
  final Future<bool> Function(BuildContext context, CommandReturn result)?
  onRun;
  final int? reorderableIndex;
  final CrossAxisAlignment crossAxisAlignment;
  final bool showShortcut;
  final bool iconOnly;
  final bool muted;
  final VoidCallback? onTap;

  @override
  State<ListTile> createState() => _ListTileState();
}

class _ListTileState extends State<ListTile> {
  FocusNode? _internalFocusNode;
  Offset? lastMousePosition;
  bool _isHovered = false;
  Offset? _tapStartPosition;
  DateTime? _tapStartTime;

  // Running state management
  bool _isRunning = false;
  Timer? _spinnerDelayTimer;
  bool _showSpinner = false;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode!;

  void _runLongPress() {
    HapticFeedback.lightImpact();
    try {
      context.run(widget.longPressCommand!);
    } catch (e, t) {
      log.warning("Action ${widget.longPressCommand?.title} failed", e, t);
    }
  }

  /// Expose run method for external triggers (e.g., Enter key in forms)
  Future<CommandReturn> run() async {
    if (_isRunning || widget.command == null || !mounted) {
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
    widget.controller?._attach(run, this);
  }

  void _onFocusChange() {
    if (mounted) setState(() {}); // Rebuild when focus changes
  }

  @override
  void didUpdateWidget(covariant ListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-attach controller when widget is updated with a new controller
    // (e.g., ListView.builder reuses the element with a new Command instance)
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(run, this);
    }
  }

  @override
  void dispose() {
    _spinnerDelayTimer?.cancel();
    _focusNode.removeListener(_onFocusChange);
    // Detach controller if provided
    widget.controller?._detach(this);
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
          enabled: widget.reorderableIndex != null && hasPhysicalKeyboard(),
          child: Builder(
            builder: (context) {
              final isHighlighted =
                  _focusNode.hasFocus ||
                  (!widget.noHoverHighlight &&
                      !widget.disableInternalHover &&
                      _isHovered) ||
                  widget.highlighted;

              final showBorder = widget.selected && widget.selectedBorder;
              // When a trailingBuilder reserves a row taller than the body
              // (e.g. the sidebar focus tiles reserve iconSizes.base * 2 so the
              // height doesn't jump when the hover button appears), the
              // body/leading tap targets would otherwise be center-aligned at
              // their shorter content height — leaving a hover-highlighted but
              // un-tappable band at the top and bottom of the row. Stretch the
              // tap targets to the full row height and re-center their content
              // so the entire highlighted row is clickable.
              // See test/widget/list_tile_hit_area_test.dart.
              final fillRowHeight = widget.trailingBuilder != null;
              Widget? fill(Widget? child) =>
                  fillRowHeight && child != null ? Center(child: child) : child;
              Widget intrinsic(Widget child) =>
                  fillRowHeight ? IntrinsicHeight(child: child) : child;
              final container = Container(
                decoration: BoxDecoration(
                  color: widget.noBackground
                      ? null
                      : widget.selected
                      ? (widget.selectedColor ??
                            context.theme.colors.primaryForeground)
                      : isHighlighted
                      ? (widget.highlightColor ??
                            context.theme.plotColors.highlight)
                      : null,
                  borderRadius: widget.borderRadius,
                  // Rounded tiles only get a border when a caller opts in via
                  // [selectedBorderColor]; the width is constant (1) so toggling
                  // selection changes only the colour, never the layout. The
                  // edge-to-edge (non-rounded) feed border is unchanged but will
                  // honour an explicit [selectedBorderColor] when provided.
                  border: widget.borderRadius != null
                      ? (widget.selectedBorderColor != null
                            ? Border.all(
                                color: showBorder
                                    ? widget.selectedBorderColor!
                                    : const Color(0x00000000),
                                width: 1,
                              )
                            : null)
                      : Border.symmetric(
                          horizontal: BorderSide(
                            color: showBorder
                                ? (widget.selectedBorderColor ??
                                      context.colour.colours.accentBackground
                                          .withLightness(
                                            context.colour.brightness ==
                                                    Brightness.light
                                                ? 0.85
                                                : 0.35,
                                          )
                                          .toColor())
                                : const Color(0x00000000),
                            width: 1,
                          ),
                        ),
                ),
                padding: EdgeInsets.only(
                  left: widget.indentLevel * (16 + context.theme.spacing.sm),
                ),
                child: intrinsic(
                  Row(
                    crossAxisAlignment: fillRowHeight
                        ? CrossAxisAlignment.stretch
                        : widget.crossAxisAlignment,
                    children: [
                      SizedBox(
                        width: widget.leadingBuilder == null
                            ? widget.padding?.resolve(null).left ?? 20
                            : 0,
                      ),

                      ...[
                        if (widget.leadingBuilder != null)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap:
                                widget.onTap ??
                                (widget.command != null ? () => run() : null),
                            // While a command is running, overlay a Spinner
                            // centered on the leading widget. The original
                            // widget is kept at 0 opacity so the slot width
                            // (and therefore the title column position) is
                            // preserved across the swap.
                            child: fill(
                              _showSpinner
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Opacity(
                                          opacity: 0,
                                          child: widget.leadingBuilder!(
                                            _isHovered,
                                            _focusNode.hasFocus,
                                          ),
                                        ),
                                        Spinner(
                                          size:
                                              widget.style ==
                                                  ListTileStyle.header
                                              ? context.theme.iconSizes.sm
                                              : context.theme.iconSizes.base,
                                          color: context.theme.plotColors.muted,
                                        ),
                                      ],
                                    )
                                  : widget.leadingBuilder!(
                                      _isHovered,
                                      _focusNode.hasFocus,
                                    ),
                            ),
                          ),
                      ].whereType<Widget>(),
                      Expanded(
                        child: hasPhysicalKeyboard()
                            // Desktop: GestureDetector participates in gesture arena,
                            // properly competes with ReorderableDragStartListener
                            ? GestureDetector(
                                behavior: fillRowHeight
                                    ? HitTestBehavior.opaque
                                    : null,
                                onTap:
                                    widget.onTap ??
                                    (widget.command != null
                                        ? () => run()
                                        : null),
                                onLongPress: widget.longPressCommand != null
                                    ? _runLongPress
                                    : null,
                                child: fill(_buildContent()),
                              )
                            // Mobile: Listener bypasses gesture arena,
                            // no conflict with Swipeable or scroll
                            : Listener(
                                behavior: fillRowHeight
                                    ? HitTestBehavior.opaque
                                    : HitTestBehavior.deferToChild,
                                onPointerDown: (event) {
                                  _tapStartPosition = event.position;
                                  _tapStartTime = Time.now();
                                },
                                onPointerUp: (event) {
                                  if (_tapStartPosition != null) {
                                    final delta =
                                        event.position - _tapStartPosition!;
                                    final duration = Time.now().difference(
                                      _tapStartTime!,
                                    );
                                    if (delta.distance < 10 &&
                                        duration <
                                            Duration(milliseconds: 500)) {
                                      if (widget.onTap != null) {
                                        widget.onTap!();
                                      } else if (widget.command != null) {
                                        run();
                                      }
                                    }
                                  }
                                  _tapStartPosition = null;
                                  _tapStartTime = null;
                                },
                                child: fill(
                                  GestureDetector(
                                    onLongPress: widget.longPressCommand != null
                                        ? _runLongPress
                                        : null,
                                    child: _buildContent(),
                                  ),
                                ),
                              ),
                      ),
                      ...[
                        if (widget.trailingBuilder != null)
                          fill(
                            widget.trailingBuilder!(
                              _isHovered,
                              _focusNode.hasFocus,
                            ),
                          ),
                      ].whereType<Widget>(),
                      SizedBox(
                        width: widget.trailingBuilder == null
                            ? widget.padding?.resolve(null).right ?? 20
                            : 0,
                      ),
                    ],
                  ),
                ),
              );

              return container;
            },
          ),
        ),
      ),
    );

    if (widget.iconOnly) {
      final tooltipText = widget.title ?? widget.command?.title;
      if (tooltipText != null) {
        return FTooltip(
          tipBuilder: (context, controller) => Text(tooltipText),
          child: child,
        );
      }
    }

    return child;
  }

  Widget _buildContent() {
    return Container(
      color: Color(0x00000000), // Transparent to capture taps
      child: Builder(
        builder: (context) {
          // Build the icon widget
          final iconSize = widget.style == ListTileStyle.header
              ? context.theme.iconSizes.sm
              : context.theme.iconSizes.base;
          final iconIsHighlighted =
              _focusNode.hasFocus || _isHovered || widget.highlighted;
          final mutedIconColor = widget.muted && iconIsHighlighted
              ? context.theme.colors.foreground
              : context.theme.plotColors.muted;
          final iconWidget = () {
            // Skip command's buildIcon when leadingBuilder already provides
            // a visual indicator (avoids double icons in priority tiles).
            final customIcon = widget.leadingBuilder == null
                ? widget.command?.buildIcon(context)
                : null;
            if (customIcon != null) {
              if (_showSpinner) {
                return Spinner(
                  size: iconSize,
                  color: context.theme.plotColors.muted,
                );
              }
              // Provide an ambient IconTheme so any Icon/FaIcon inside the
              // custom widget picks up the same muted/primary color used by
              // the IconData fallback below. Custom icons that set their
              // own color (e.g. avatars, logos) override this.
              return IconTheme.merge(
                data: IconThemeData(
                  size: iconSize,
                  color: widget.command?.on == true
                      ? context.theme.colors.primary
                      : mutedIconColor,
                ),
                child: customIcon,
              );
            }

            // Fall back to IconData icon
            if (widget.icon != null || widget.command?.icon != null) {
              if (_showSpinner) {
                return Spinner(
                  size: iconSize,
                  color: context.theme.plotColors.muted,
                );
              }
              return Icon(
                widget.icon ?? widget.command?.icon,
                size: iconSize,
                color: widget.command?.on == true
                    ? context.theme.colors.primary
                    : mutedIconColor,
              );
            }

            return const SizedBox.shrink();
          }();

          // Only apply spacing when icon is present
          final hasIcon = iconWidget is! SizedBox;
          // Normalize the leading slot to a fixed iconSize square so swapping
          // in a Spinner (always iconSize wide) doesn't shift the title for
          // custom icons whose natural width is narrower than iconSize
          // (e.g. FaIcon, which doesn't wrap itself in a SizedBox).
          final normalizedIcon = hasIcon
              ? SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: Center(child: iconWidget),
                )
              : iconWidget;

          if (widget.iconOnly) {
            return Center(
              child: Padding(
                padding:
                    (widget.padding?.resolve(null) ??
                            context.theme.spacing.paddingSm)
                        .copyWith(left: 0, right: 0),
                child: normalizedIcon,
              ),
            );
          }

          final contentPadding =
              (widget.padding?.resolve(null) ?? context.theme.spacing.paddingSm)
                  .copyWith(
                    left: 0,
                    right: 0,
                    top: widget.style == ListTileStyle.header ? 2 : null,
                    bottom: widget.style == ListTileStyle.header ? 2 : null,
                  );

          final mainRow = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: hasIcon ? 12 : 0,
            children: [
              normalizedIcon,
              Expanded(
                child: Padding(
                  padding: contentPadding,
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
                              ? Row(children: [Expanded(child: commandBody)])
                              : Text.rich(
                                  TextSpan(
                                    style: TextStyle(height: 1),
                                    children: [
                                      TextSpan(
                                        text:
                                            widget.title ??
                                            widget.command?.title ??
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
                                                              .md))
                                                .copyWith(
                                                  color: widget.selected
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
                                                      : widget.muted &&
                                                            !isHighlighted
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
                                      if (widget.subtitle != null)
                                        TextSpan(
                                          text: '  ${widget.subtitle!}',
                                          style:
                                              (widget.textStyle ??
                                                      context
                                                          .theme
                                                          .typography
                                                          .md)
                                                  .copyWith(
                                                    color: context
                                                        .theme
                                                        .plotColors
                                                        .muted,
                                                  ),
                                        ),
                                    ],
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: widget.centered
                                      ? TextAlign.center
                                      : TextAlign.start,
                                );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.showShortcut &&
                  widget.command?.shortcut != null &&
                  hasPhysicalKeyboard())
                Text(
                  formatShortcut(widget.command?.shortcut),
                  style: context.theme.typography.md.copyWith(
                    color: context.theme.plotColors.muted,
                  ),
                ),
            ],
          );

          if (widget.details == null) return mainRow;

          // Details go below the row so the icon stays aligned with the title
          final iconOffset = hasIcon ? iconSize + 12 : 0.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mainRow,
              Padding(
                padding: EdgeInsets.only(left: iconOffset),
                child: widget.details!,
              ),
            ],
          );
        },
      ),
    );
  }
}
