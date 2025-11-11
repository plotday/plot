import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:forui/forui.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/action/action.dart';
import 'package:plot/state/layout.dart';
import 'button.dart';
import 'icon.dart';
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
    this.actions = const [],
    this.onSearchChanged,
    this.modal = false,
    this.position,
    super.key,
  });

  final Widget? main;
  final String? title;
  final List<Action> actions;
  final void Function(String)? onSearchChanged;
  final bool modal;
  final HeaderPosition? position;

  @override
  State<Header> createState() => _HeaderState();
}

class _HeaderState extends State<Header> with RouteAware {
  late final RouteObserver<ModalRoute<dynamic>> _routeObserver;
  bool _canPop = false;
  bool _searchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _routeObserver = RouteObserver<ModalRoute<dynamic>>();
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCanPop();
    final route = ModalRoute.of(context);
    if (route != null) {
      _routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    _routeObserver.unsubscribe(this);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _updateCanPop() {
    final canPop = context.router.canPop();
    if (_canPop != canPop) {
      setState(() {
        _canPop = canPop;
      });
    }
  }

  @override
  void didPush() {
    _updateCanPop();
  }

  @override
  void didPop() {
    _updateCanPop();
  }

  @override
  void didPopNext() {
    _updateCanPop();
  }

  @override
  void didPushNext() {
    _updateCanPop();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final layoutBloc = context.read<LayoutBloc>();

        // Auto-detect position if not provided
        final position =
            widget.position ??
            PanelPositionProvider.of(context) ??
            HeaderPosition.middle;

        // Build title with position-specific left buttons
        final titleChildren = <Widget>[
          if (!layoutState.multiPanel ||
              position == HeaderPosition.left ||
              (!layoutState.leftPanelVisible &&
                  position == HeaderPosition.middle))
            SizedBox(width: Window.toolbarPadding.horizontal),
          // Left sidebar toggle for middle position when left panel is hidden
          if (layoutState.multiPanel &&
              position == HeaderPosition.middle &&
              !layoutState.leftPanelVisible)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () => layoutBloc.setLeftPanelVisible(true),
              child: Icon(PlotIcon.sidebarLeft, size: 14),
            ),
          // Back button for modal/navigation
          if (!widget.modal && _canPop && layoutState.showBackButton)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () => context.router.maybePop(),
              child: Icon(PlotIcon.back, size: 14),
            ),
          // If search is expanded, show the search field here
          if (_searchExpanded && widget.onSearchChanged != null)
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                    setState(() {
                      _searchExpanded = false;
                    });
                    widget.onSearchChanged!('');
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: FTextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  hint: 'Search...',
                  style: (style) => style.copyWith(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
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
                    style: context.theme.typography.sm,
                  ),
            ),
        ];

        // Build suffixes with position-specific right buttons
        final suffixes = <Widget>[
          // Add search button/close button if onSearchChanged is provided
          if (widget.onSearchChanged != null)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () {
                setState(() {
                  _searchExpanded = !_searchExpanded;
                  if (_searchExpanded) {
                    // Focus the text field when expanding
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _searchFocusNode.requestFocus();
                    });
                  } else {
                    // Clear search when collapsing
                    _searchController.clear();
                    widget.onSearchChanged!('');
                  }
                });
              },
              child: Icon(_searchExpanded ? PlotIcon.close : PlotIcon.search, size: 14),
            ),
          ...widget.actions.asMap().entries.map((entry) {
            final key = ValueKey(Object.hash(entry.value.hashCode, entry.key));
            return Button.icon(entry.value, key: key);
          }),
          // Left sidebar toggle for left position
          if (position == HeaderPosition.left)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () => layoutBloc.setLeftPanelVisible(false),
              child: Icon(PlotIcon.sidebarLeft, size: 14),
            ),
          // Right sidebar toggle for right position
          if (position == HeaderPosition.right)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () async {
                context.read<LayoutBloc>().setRightPanelVisible(false);
                // Navigate to the parent PriorityRoute by popping the current ActivityRoute
                await context.router.maybePop();
              },
              child: Icon(PlotIcon.sidebarRight, size: 14),
            ),
          // Modal close button
          if (widget.modal && _canPop)
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: () => context.router.maybePop(),
              child: Icon(PlotIcon.close, size: 14),
            ),
        ];

        return FHeader(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: titleChildren,
          ),
          suffixes: suffixes,
        );
      },
    );
  }
}
