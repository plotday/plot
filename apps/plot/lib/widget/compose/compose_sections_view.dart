import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/store/store.dart' show Priority, Uuid;
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/compose_search_field.dart';
import 'package:plot/widget/compose/pill_grid.dart';
import 'package:plot/widget/icon.dart';

/// The step-1 "sections" view of the new-thread picker.
///
/// Displays a [ComposeSearchField] above a [PillGrid] partitioned into three
/// sections — **People & twists**, **Channels**, and **Private notes** — each
/// populated from [ComposeTargetsBloc.loadSections] /
/// [ComposeTargetsBloc.searchSections].
///
/// Selecting a people entry invokes [onPickRecipient] (→ step 2 connection
/// picker); selecting a twist, channel, or focus target invokes [onPickTarget]
/// (→ compose directly).
///
/// The view owns a debounced search loop (180 ms) and restores any
/// pre-filled filter text on mount so round-tripping back from step 2 shows
/// the same filtered results.
class ComposeSectionsView extends StatefulWidget {
  const ComposeSectionsView({
    super.key,
    required this.scrollController,
    required this.searchController,
    required this.searchFocusNode,
    required this.onPickRecipient,
    required this.onPickTarget,
    this.onBack,
    this.autofocusSearch = true,
    this.activeListenable,
  });

  /// Scroll controller for the pill grid (owned by the host page so it
  /// persists across step round-trips).
  final ScrollController scrollController;

  /// The search text controller. Owned by the page so the filter text
  /// survives navigation back from step 2.
  final TextEditingController searchController;

  /// Focus node for the search field. Owned by the page so the page can
  /// re-focus it when returning to step 1.
  final FocusNode searchFocusNode;

  /// Called when the user picks a people pill (→ advance to the connection
  /// picker in step 2).
  final void Function(ComposePeopleEntry entry) onPickRecipient;

  /// Called when the user picks a twist, channel, or focus pill (→ start
  /// compose with the chosen target).
  final void Function(ComposeTarget target) onPickTarget;

  /// Optional "go back" affordance. When provided, the search field's leading
  /// slot becomes a back button (in place of the search icon) that invokes
  /// this — used in single-panel mode where the global header no longer
  /// carries a back button. Null in multi-panel, where the leading stays a
  /// plain search icon.
  final VoidCallback? onBack;

  /// Whether to autofocus the search field on mount. Enabled by default (the
  /// page's normal open); the host can disable it when restoring step 1 after
  /// the user returns from step 2 and already has a typed filter.
  final bool autofocusSearch;

  /// Forwarded to [ComposeSearchField.activeListenable]: when the host fades the
  /// panel in its inactive state, this carries the active-state so the "Start a
  /// thread" hint holds its level through the fade. Null disables the boost
  /// (e.g. single-panel mode, where the panel never fades).
  final ValueListenable<bool>? activeListenable;

  @override
  State<ComposeSectionsView> createState() => _ComposeSectionsViewState();
}

class _ComposeSectionsViewState extends State<ComposeSectionsView> {
  // ─── State ─────────────────────────────────────────────────────────────────

  /// Most-recently-loaded sectioned data. Null while the initial load is in
  /// flight (the grid shows an empty placeholder).
  ComposeSections? _sections;

  /// Priorities by id, co-loaded with [_sections], used to resolve a
  /// focus-note target's [ComposeTarget.priorityId] into a [Priority] for
  /// [FocusPillData].
  Map<Uuid, Priority> _priorityById = const {};

  /// Monotonic request counter used to discard stale responses.
  int _requestId = 0;

  /// Debounce timer for the search field.
  Timer? _debounce;

  static const Duration _searchDebounce = Duration(milliseconds: 180);

  bool _isDisposed = false;

  /// Key for the [PillGrid]; drives [PillGridState.moveHighlight] /
  /// [PillGridState.activateHighlighted] as the user navigates the search field.
  final _gridKey = GlobalKey<PillGridState>();

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Restore a pre-filled filter (returning from step 2) or load at rest.
    if (widget.searchController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _runSearch(widget.searchController.text);
      });
    } else {
      _loadSections();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounce?.cancel();
    super.dispose();
  }

  // ─── Data loading ──────────────────────────────────────────────────────────

  /// Loads sections at rest (no query) and populates [_priorityById].
  void _loadSections() {
    final requestId = ++_requestId;
    final bloc = context.read<ComposeTargetsBloc>();
    bloc
        .loadSections()
        .then((sections) async {
          if (_isDisposed || requestId != _requestId) return;
          // Co-load priorities in parallel so focus-note pills can resolve.
          final priorities = await Priority.getRaw();
          if (_isDisposed || requestId != _requestId) return;
          setState(() {
            _sections = sections;
            _priorityById = {for (final p in priorities) p.id: p};
          });
        })
        .catchError((Object e, StackTrace s) {
          Tracker.captureException(e, s);
        });
  }

  /// Runs a debounced search for [query], or delegates to [_loadSections] when
  /// the query is empty.
  void _onSearchChanged() {
    _debounce?.cancel();
    final query = widget.searchController.text.trim();
    if (query.isEmpty) {
      _loadSections();
      return;
    }
    _debounce = Timer(_searchDebounce, () {
      if (_isDisposed) return;
      _runSearch(query);
    });
  }

  void _runSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _loadSections();
      return;
    }
    final requestId = ++_requestId;
    final bloc = context.read<ComposeTargetsBloc>();
    bloc
        .searchSections(trimmed)
        .then((sections) async {
          if (_isDisposed || requestId != _requestId) return;
          final priorities = await Priority.getRaw();
          if (_isDisposed || requestId != _requestId) return;
          setState(() {
            _sections = sections;
            _priorityById = {for (final p in priorities) p.id: p};
          });
        })
        .catchError((Object e, StackTrace s) {
          Tracker.captureException(e, s);
        });
  }

  // ─── Section building ──────────────────────────────────────────────────────

  List<PillGridSection> _buildSections() {
    final s = _sections;
    if (s == null) return const [];
    final sections = <PillGridSection>[];

    // 1. People & twists
    final personItems = [
      for (final e in s.people)
        PillGridItem(
          data: e.display,
          onActivate: () => widget.onPickRecipient(e),
        ),
    ];
    final twistItems = [
      for (final t in s.twists)
        PillGridItem(
          data: TwistPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    // At rest, recently-used people lead. Under an active query, twists go first
    // so an explicit name search (e.g. "Plot") surfaces the matching twist at the
    // top instead of being buried below contacts that incidentally match (e.g.
    // anyone with an @plot.day email).
    final hasQuery = widget.searchController.text.trim().isNotEmpty;
    final peopleItems = hasQuery
        ? [...twistItems, ...personItems]
        : [...personItems, ...twistItems];
    if (peopleItems.isNotEmpty) {
      sections.add(
        PillGridSection(header: _peopleHeader(), items: peopleItems),
      );
    }

    // 2. Channels
    final channelItems = [
      for (final t in s.channels)
        PillGridItem(
          data: ChannelPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    if (channelItems.isNotEmpty) {
      sections.add(
        PillGridSection(
          header: _sectionHeader('Channels'),
          items: channelItems,
        ),
      );
    }

    // 3. Private notes (focuses)
    final focusItems = <PillGridItem>[];
    for (final t in s.focuses) {
      final pid = t.priorityId;
      if (pid == null) continue;
      final priority = _priorityById[pid];
      if (priority == null) continue;
      focusItems.add(
        PillGridItem(
          data: FocusPillData(priority),
          onActivate: () => widget.onPickTarget(t),
        ),
      );
    }
    if (focusItems.isNotEmpty) {
      sections.add(
        PillGridSection(
          header: _sectionHeader('Private note'),
          items: focusItems,
        ),
      );
    }

    return sections;
  }

  // ─── Header widgets ────────────────────────────────────────────────────────

  /// The "People and twists" section header.
  Widget _peopleHeader() => _sectionHeader('People and twists');

  /// A plain section-label widget using the shared heading style.
  Widget _sectionHeader(String text) {
    return Builder(
      builder: (context) => Text(text, style: _headingStyle(context)),
    );
  }

  /// Section-heading text style: a calm step up in size from the body and
  /// muted so each group reads as a clear divider. Matches the colour
  /// (`muted`) and weight (`w500`) of the thread-list section headings.
  TextStyle _headingStyle(BuildContext context) {
    return context.theme.typography.sm.copyWith(
      color: context.theme.colors.mutedForeground,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.3,
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    final colors = context.theme.colors;

    // Single-panel mode hands a back affordance down so it can stand in for
    // the (now-dropped) global header back button; otherwise the leading
    // slot is empty. The back button mirrors the step-2 connection picker's
    // leading affordance (PlotIcon.left, muted).
    final Widget? leading = widget.onBack != null
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onBack,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Icon(
                PlotIcon.left,
                size: 18,
                color: colors.mutedForeground,
              ),
            ),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ComposeSearchField(
          controller: widget.searchController,
          focusNode: widget.searchFocusNode,
          hint: 'Start a thread',
          hintDetail: 'with a name, email, channel, or focus',
          autofocus: widget.autofocusSearch,
          activeListenable: widget.activeListenable,
          leading: leading,
          onChanged: _onSearchChanged,
          onArrowDown: () => _gridKey.currentState?.moveHighlight(1),
          onArrowUp: () => _gridKey.currentState?.moveHighlight(-1),
          onSubmit: () => _gridKey.currentState?.activateHighlighted(),
          onEscape: null,
        ),
        SizedBox(height: spacing.lg),
        Expanded(
          child: _sections == null
              ? const SizedBox.shrink()
              : PillGrid(
                  key: _gridKey,
                  sections: _buildSections(),
                  scrollController: widget.scrollController,
                ),
        ),
      ],
    );
  }
}
