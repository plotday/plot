import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
import 'button.dart';
import 'window.dart';

enum HeaderPosition { left, middle, right }

class PanelPositionProvider extends InheritedWidget {
  const PanelPositionProvider({
    super.key,
    required this.position,
    required super.child,
  });

  final HeaderPosition position;

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
            return Button.icon(entry.value, key: key);
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

        return FHeader(
          style: (style) {
            final resolvedPadding = style.padding.resolve(TextDirection.ltr);
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
        );
      },
    );
  }
}
