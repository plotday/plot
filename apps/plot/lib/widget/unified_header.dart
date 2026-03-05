import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';

import 'package:plot/command/command.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/state/layout.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/priority_selector.dart';
import 'button.dart';
import 'icon.dart';
import 'window.dart';

/// A single header spanning the full window width, placed above all panels.
class UnifiedHeader extends StatefulWidget {
  const UnifiedHeader({super.key});

  @override
  State<UnifiedHeader> createState() => _UnifiedHeaderState();
}

class _UnifiedHeaderState extends State<UnifiedHeader> {
  bool _searchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  PriorityShortcutsProviderState? _panelController;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panelController = ActivityPanelControllerProvider.maybeOf(context);
    _panelController?.registerSearchToggle(_toggleSearch);
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      final search = _searchController.text;
      // Dispatch to PriorityBloc
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateSearch(search);
      // Dispatch to PrioritiesBloc to filter sidebar
      context.read<PrioritiesBloc>().updateSearch(search);
      // Dispatch to ThreadHeaderNotifier if activity is visible
      final notifier = ThreadHeaderNotifierProvider.of(context);
      notifier?.onSearchChanged?.call(search);
    });
  }

  void _toggleSearch() {
    if (_searchExpanded) {
      _closeSearch();
    } else {
      setState(() {
        _searchExpanded = true;
        _panelController?.updateSearchExpanded(true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      });
    }
  }

  void _closeSearch() {
    setState(() {
      _searchExpanded = false;
      _panelController?.updateSearchExpanded(false);
      _searchController.clear();
    });
    // Clear PriorityBloc search and filters
    context.read<PriorityBloc>().updateSearch('');
    context.read<PriorityBloc>().updateFilter([]);
    // Clear PrioritiesBloc search
    context.read<PrioritiesBloc>().updateSearch('');
    // Clear activity search
    final notifier = ThreadHeaderNotifierProvider.of(context);
    notifier?.onSearchChanged?.call('');
    notifier?.onSearchClosed?.call();
  }

  @override
  void dispose() {
    _panelController?.unregisterSearchToggle();
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
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            final notifier = ThreadHeaderNotifierProvider.of(context);

            return ListenableBuilder(
              listenable: notifier ?? ChangeNotifier(),
              builder: (context, _) {
                return _buildHeader(context, layoutState, state, notifier);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );

    final isThreadVisible = notifier?.isThreadVisible ?? false;
    final hasActivity = state.thread != null || isThreadVisible;

    // --- Build title children ---
    final titleChildren = <Widget>[
      // macOS traffic light padding
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),

      // Toggle/Back button
      if (!layoutState.multiPanel && hasActivity)
        Button.icon(
          CommandWrapper(
            ChangeCurrentThread(null),
            icon: Value(PlotIcon.back),
          ),
        )
      else if (layoutState.multiPanel)
        Button.icon(CyclePanelsCommand(layoutState: layoutState)),

      // Search field or title + search button
      if (_searchExpanded) ...[
        // Invisible button-height spacer to keep the row height constant
        SizedBox(
          width: 0,
          child: Opacity(
            opacity: 0,
            child: IgnorePointer(child: _searchButton()),
          ),
        ),
        _buildSearchField(context, layoutState, state, notifier),
      ] else
        _buildTitleWithSearch(context, layoutState, state, hasActivity),
    ];

    // --- Build suffixes ---
    final thread = state.thread;
    final suffixes = <Widget>[
      // Active tag toggles (when thread is visible)
      if (thread != null)
        ..._buildActiveTagToggles(context, thread, notifier),

      // Todo toggle (when thread is visible)
      if (thread != null) _buildTodoToggle(context, thread),

      // New Thread button (multiPanel only, since bottom nav has it otherwise)
      if (layoutState.multiPanel) Button.icon(NewThread()),

      // Menu button
      Button.icon(_buildMenuCommand(state, layoutState, notifier)),

      // Windows window control padding
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
    ];

    Widget header = FAnimatedTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => ClipRect(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.theme.colors.background,
              border: Border(
                bottom: BorderSide(
                  color: context.theme.colors.border,
                  width: 1,
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
    );

    // Wrap with DragToMoveArea on Windows
    if (Platform.instance.isWindows) {
      header = DragToMoveArea(child: header);
    }

    return header;
  }

  Widget _searchButton() {
    return Button.icon(
      ToggleSearchCommand(
        searchExpanded: _searchExpanded,
        onToggle: _toggleSearch,
      ),
    );
  }

  Widget _buildTitleWithSearch(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    bool hasActivity,
  ) {
    final search = _searchButton();

    // In single panel with a thread visible, show activity title
    if (!layoutState.multiPanel && hasActivity && state.thread != null) {
      return Expanded(
        child: Row(
          spacing: 8,
          children: [
            Flexible(
              child: Text(
                state.thread!.displayTitle,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.base,
              ),
            ),
            search,
          ],
        ),
      );
    }

    // Default: show PrioritySelector with search button
    final selector = PrioritySelector(
      selected: state.context,
      onSelect: (p) => context.run(ChangeCurrentPriority(p)),
    );

    return Expanded(
      child: Row(
        spacing: 8,
        children: [
          Flexible(child: selector),
          search,
        ],
      ),
    );
  }

  Widget _buildSearchField(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    // Build filter commands based on visibility
    final filterCommands = <Command>[
      // Priority tag filters
      ...state.tags.map(
        (tagData) => ToggleActivityFilter(tagData.$1, context: context),
      ),
      // Active filter tags not in current priority
      ...state.filter
          .where((tag) => !state.tags.any((t) => t.$1 == tag))
          .map((tag) => ToggleActivityFilter(tag, context: context)),
      // Activity note filters (when activity is visible)
      if (notifier?.isThreadVisible == true)
        ...notifier!.tags.map(
          (tagData) => ToggleNoteFilter(tagData.$1, context: context),
        ),
    ];

    return Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _closeSearch();
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
                    vertical: 2,
                  ),
                ),
                suffixBuilder: (context, style, states) {
                  final children = <Widget>[
                    ...filterCommands.asMap().entries.map((entry) {
                      final key = ValueKey(
                        Object.hash(entry.value.hashCode, entry.key),
                      );
                      return Button.icon(
                        entry.value,
                        key: key,
                        selected: entry.value.on == true,
                      );
                    }),
                    Button.icon(
                      ToggleSearchCommand(
                        searchExpanded: _searchExpanded,
                        onToggle: _closeSearch,
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
      ),
    );
  }

  /// Builds the todo toggle button matching ThreadWidget's leading icon behavior.
  Widget _buildTodoToggle(BuildContext context, Thread thread) {
    final threadColor = context.colour.colours.fromTheme(
      thread.priority.displayColor,
    );
    final isTodo = thread.todo;

    final Command command;
    if (!isTodo) {
      command = CommandWrapper(
        ThreadToDo(thread),
        icon: Value(PlotIcon.addTodo),
      );
    } else if (thread.isFuture) {
      command = CommandWrapper(
        ThreadDone(thread),
        icon: Value(PlotIcon.schedule),
      );
    } else {
      command = CommandWrapper(
        ThreadDone(thread),
        icon: Value(PlotIcon.todo),
      );
    }

    return Button.icon(
      command,
      selected: isTodo,
      selectedColor: threadColor,
      color: isTodo ? null : context.theme.plotColors.veryMuted,
    );
  }

  /// Builds active tag toggle buttons for the current thread.
  List<Widget> _buildActiveTagToggles(
    BuildContext context,
    Thread thread,
    ThreadHeaderNotifier? notifier,
  ) {
    final tags = notifier?.tags ?? const [];
    return tags
        .where((tagData) => thread.hasTag(tagData.$1))
        .take(3)
        .map((tagData) => Button.icon(ToggleThreadTag(thread, tagData.$1)))
        .toList();
  }

  Command _buildMenuCommand(
    PriorityState state,
    LayoutState layoutState,
    ThreadHeaderNotifier? notifier,
  ) {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final thread = state.thread;
        final threadGroups = thread != null
            ? await threadCommandGroups(thread)
            : <StaticCommandGroup>[];
        return Commands(
          groups: [
            ...threadGroups,
            ...currentPriorityCommandGroups(state.context),
          ],
        );
      },
    );
  }
}
