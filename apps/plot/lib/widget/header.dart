import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/theme.dart';
import 'button.dart';
import 'window.dart';

enum HeaderPosition { left, middle, right }

class PanelPositionProvider extends InheritedWidget {
  const PanelPositionProvider({
    super.key,
    required this.position,
    required super.child,
  });

  final HeaderPosition? position;

  static HeaderPosition? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PanelPositionProvider>()
        ?.position;
  }

  @override
  bool updateShouldNotify(PanelPositionProvider oldWidget) {
    return position != oldWidget.position;
  }
}

/// Provides a [ValueNotifier] for header height to descendants.
/// Used to offset the resize hover overlay below the header area.
class HeaderHeightProvider extends InheritedWidget {
  const HeaderHeightProvider({
    super.key,
    required this.notifier,
    required super.child,
  });

  final ValueNotifier<double> notifier;

  static ValueNotifier<double>? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<HeaderHeightProvider>()
        ?.notifier;
  }

  @override
  bool updateShouldNotify(HeaderHeightProvider oldWidget) {
    return notifier != oldWidget.notifier;
  }
}

class Header extends StatefulWidget {
  const Header({
    this.main,
    this.title,
    this.prefixCommands = const [],
    this.filterCommands = const [],
    this.commands = const [],
    this.onSearchChanged,
    this.onSearchClosed,
    this.modal = false,
    this.position,
    super.key,
  });

  final Widget? main;
  final String? title;
  final List<Command> prefixCommands;
  final List<Command> filterCommands;
  final List<Command> commands;
  final void Function(String)? onSearchChanged;
  final void Function()? onSearchClosed;
  final bool modal;
  final HeaderPosition? position;

  @override
  State<Header> createState() => _HeaderState();
}

class _HeaderState extends State<Header> {
  bool _searchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    // Cancel previous timer
    _debounceTimer?.cancel();

    // Create new timer with 250ms delay
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      final search = _searchController.text;
      widget.onSearchChanged?.call(search);
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        // Auto-detect position if not provided
        final position =
            widget.position ??
            PanelPositionProvider.of(context) ??
            HeaderPosition.right;

        // Build title with position-specific left buttons
        final titleChildren = <Widget>[
          // Avoid the window button area on the first panel
          if (Window.toolbarPadding.horizontal != 0 &&
              (!layoutState.multiPanel ||
                  position == HeaderPosition.left ||
                  (!layoutState.leftPanelVisible &&
                      position == HeaderPosition.middle) ||
                  (!layoutState.leftPanelVisible &&
                      !layoutState.middlePanelVisible)))
            SizedBox(width: Window.toolbarPadding.horizontal),
          // Right sidebar toggle for right position when panel is open
          if (position == HeaderPosition.right &&
              !layoutState.middlePanelVisible &&
              layoutState.multiPanel)
            Button.icon(
              ToggleMiddleSidebarCommand(
                isVisible: layoutState.middlePanelVisible,
              ),
            ),
          // Left sidebar toggle for middle position when left panel is hidden
          if (layoutState.multiPanel &&
              position == HeaderPosition.middle &&
              !layoutState.leftPanelVisible)
            Button.icon(
              ToggleLeftSidebarCommand(isVisible: layoutState.leftPanelVisible),
            ),
          // Prefix actions provided by the page
          ...widget.prefixCommands.asMap().entries.map((entry) {
            final key = ValueKey(Object.hash(entry.value.hashCode, entry.key));
            return Button.icon(entry.value, key: key);
          }),
          // If search is expanded, show the search field here
          if (_searchExpanded && widget.onSearchChanged != null)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      setState(() {
                        _searchExpanded = false;
                      });
                      widget.onSearchChanged!('');
                      widget.onSearchClosed?.call();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: FTextField(
                    control: .managed(controller: _searchController),
                    focusNode: _searchFocusNode,
                    hint: 'Search…',
                    style: (style) => style.copyWith(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    suffixBuilder: (context, style, states) {
                      final children = <Widget>[
                        // Filter command buttons
                        ...widget.filterCommands.asMap().entries.map((entry) {
                          final key = ValueKey(
                            Object.hash(entry.value.hashCode, entry.key),
                          );
                          return Button.icon(
                            entry.value,
                            key: key,
                            selected: entry.value.on == true,
                          );
                        }),
                        // Close search button
                        Button.icon(
                          ToggleSearchCommand(
                            searchExpanded: _searchExpanded,
                            onToggle: () {
                              setState(() {
                                _searchExpanded = false;
                                _searchController.clear();
                                widget.onSearchChanged!('');
                                widget.onSearchClosed?.call();
                              });
                            },
                          ),
                        ),
                      ];

                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: children,
                      );
                    },
                  ),
                ),
              ),
            ),
          // Main content or title (hidden when search is expanded)
          if (!_searchExpanded && (widget.main ?? widget.title) != null)
            Expanded(
              child:
                  widget.main ??
                  Text(
                    widget.title!,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.base,
                  ),
            ),
          // Invisible button-height spacer for blank headers to match height
          if (!_searchExpanded && widget.main == null && widget.title == null)
            Expanded(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0,
                  child: FButton.icon(
                    onPress: null,
                    child: SizedBox.square(
                      dimension: context.theme.iconSizes.base,
                    ),
                  ),
                ),
              ),
            ),
        ];

        // Build suffixes with position-specific right buttons
        final suffixes = <Widget>[
          // Add search button to activate search (only when not expanded)
          if (widget.onSearchChanged != null && !_searchExpanded)
            Button.icon(
              ToggleSearchCommand(
                searchExpanded: _searchExpanded,
                onToggle: () {
                  setState(() {
                    _searchExpanded = true;
                    // Focus the text field when expanding
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _searchFocusNode.requestFocus();
                    });
                  });
                },
              ),
            ),
          ...widget.commands.asMap().entries.map((entry) {
            final key = ValueKey(Object.hash(entry.value.hashCode, entry.key));
            return Button.icon(
              entry.value,
              key: key,
              selected: entry.value.on == true,
            );
          }),
          // Left sidebar toggle for left position
          if (position == HeaderPosition.left)
            Button.icon(
              ToggleLeftSidebarCommand(isVisible: layoutState.leftPanelVisible),
            ),
          // Right sidebar show button for middle position when right panel is hidden
          if (position == HeaderPosition.middle)
            Button.icon(
              ToggleMiddleSidebarCommand(
                isVisible: layoutState.middlePanelVisible,
              ),
            ),
        ];

        return _HeaderHeightReporter(
          child: FAnimatedTheme(
            data: darkenTheme(context, context.theme, context.colour, steps: 2),
            child: Builder(
              builder: (context) => ClipRect(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.theme.colors.background,
                    border: Border(
                      bottom: BorderSide(
                        color: context.theme.colors.border,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: FHeader(
                    style: (style) {
                      final resolvedPadding = style.padding.resolve(
                        TextDirection.ltr,
                      );
                      return style.copyWith(
                        padding: EdgeInsets.fromLTRB(
                          resolvedPadding.left,
                          resolvedPadding.top,
                          resolvedPadding.right,
                          8,
                        ),
                      );
                    },
                    title: Row(spacing: 8, children: titleChildren),
                    suffixes: suffixes,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reports its measured height to the nearest [HeaderHeightProvider].
class _HeaderHeightReporter extends StatefulWidget {
  const _HeaderHeightReporter({required this.child});

  final Widget child;

  @override
  State<_HeaderHeightReporter> createState() => _HeaderHeightReporterState();
}

class _HeaderHeightReporterState extends State<_HeaderHeightReporter> {
  void _reportHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final height = context.size?.height;
      final notifier = HeaderHeightProvider.of(context);
      if (height != null && notifier != null && notifier.value != height) {
        notifier.value = height;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _reportHeight();
    return widget.child;
  }
}
