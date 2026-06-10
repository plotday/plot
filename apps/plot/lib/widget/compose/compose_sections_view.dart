import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/store/store.dart' show Priority, Uuid;
import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/compose_search_field.dart';
import 'package:plot/widget/compose/pill_grid.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';

/// The link currently held in the step-1 picker (URL plus resolved metadata).
/// When non-null the search field is replaced by a chip and the picker renders
/// in link mode.
class LinkChipData {
  const LinkChipData({required this.url, this.title, this.favicon});
  final String url;
  final String? title;
  final String? favicon;

  /// What the chip shows: the resolved title, else the raw URL.
  String get display {
    final t = title;
    return (t != null && t.isNotEmpty) ? t : url;
  }
}

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
    this.onCreateTopic,
    this.onRowMore,
    this.onAddContact,
    this.onAddGroup,
    this.autofocusSearch = true,
    this.activeListenable,
    this.pendingLink,
    this.onClearLink,
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

  /// Called when the user taps the "+ Topic" affordance in the Channels header
  /// to create a new Plot topic. Returns true when a topic was created (so the
  /// section list is reloaded to surface it). Null hides the affordance.
  final Future<bool> Function()? onCreateTopic;

  /// Opens the "… More" (Edit) menu for an editable people row. Null hides
  /// the affordance.
  final Future<void> Function(ComposePillData data)? onRowMore;

  /// Opens the add-contact form (People & twists header "+ Contact"). Returns
  /// true when a contact was added (so sections reload). Null hides the button.
  final Future<bool> Function()? onAddContact;

  /// Opens the add-group form (People & twists header "+ Group"). Returns true
  /// when a group was created. Null hides the button.
  final Future<bool> Function()? onAddGroup;

  /// Whether to autofocus the search field on mount. Enabled by default (the
  /// page's normal open); the host can disable it when restoring step 1 after
  /// the user returns from step 2 and already has a typed filter.
  final bool autofocusSearch;

  /// Forwarded to [ComposeSearchField.activeListenable]: when the host fades the
  /// panel in its inactive state, this carries the active-state so the "Start a
  /// thread" hint holds its level through the fade. Null disables the boost
  /// (e.g. single-panel mode, where the panel never fades).
  final ValueListenable<bool>? activeListenable;

  /// When non-null, the picker is in link mode: the search field is replaced
  /// by a link chip and the sections show Private notes then link-supporting
  /// Channels (People & twists hidden). Null = normal text-filter mode.
  final LinkChipData? pendingLink;

  /// Clears the pending link (the chip's ✕), returning to text-filter mode.
  final VoidCallback? onClearLink;

  @override
  State<ComposeSectionsView> createState() => _ComposeSectionsViewState();
}

class _ComposeSectionsViewState extends State<ComposeSectionsView> {
  bool get _linkMode => widget.pendingLink != null;

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

  /// Subscription to the bloc's reactive emissions. [ComposeTargetsBloc]
  /// refreshes (and re-emits) when the underlying connections/channels change —
  /// a connection added or archived mid-session. The sectioned data we render
  /// is derived from those same stores, so we re-run the current load/search on
  /// every emission. Without this the Channels list only reflected connection
  /// changes after an app restart (the view loaded once in [initState]).
  StreamSubscription<ComposeTargetsState>? _blocSub;

  bool _isDisposed = false;

  /// Key for the [PillGrid]; drives [PillGridState.moveHighlight] /
  /// [PillGridState.activateHighlighted] as the user navigates the search field.
  final _gridKey = GlobalKey<PillGridState>();

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Restore a pre-filled filter (returning from step 2) or load at rest.
    if (!_linkMode && widget.searchController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _runSearch(widget.searchController.text);
      });
    } else {
      _loadSections();
    }
    // Reload whenever connections/channels change (the bloc re-emits on its
    // reactive refresh) so newly-added or archived channels appear/disappear
    // without an app restart.
    _blocSub = context.read<ComposeTargetsBloc>().stream.listen((_) {
      if (!_isDisposed) _reload();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounce?.cancel();
    _blocSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ComposeSectionsView old) {
    super.didUpdateWidget(old);
    final enteringLinkMode =
        old.pendingLink == null && widget.pendingLink != null;
    final exitingLinkMode =
        old.pendingLink != null && widget.pendingLink == null;
    if (enteringLinkMode) {
      // The IndexedStack keeps the (now-hidden) search field in the tree; drop
      // its focus so typing can't land in an invisible field.
      widget.searchFocusNode.unfocus();
    }
    if (enteringLinkMode || exitingLinkMode) {
      _loadSections();
    }
  }

  // ─── Data loading ──────────────────────────────────────────────────────────

  /// Loads sections at rest (no query) and populates [_priorityById].
  void _loadSections() {
    final requestId = ++_requestId;
    final bloc = context.read<ComposeTargetsBloc>();
    bloc
        .loadSections(linkMode: _linkMode)
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

    // People & twists (hidden in link mode, where s.people/s.twists are empty).
    final personItems = [
      for (final e in s.people)
        PillGridItem(
          data: e.display,
          onActivate: () => widget.onPickRecipient(e),
          onMore: _rowMoreFor(e.display),
        ),
    ];
    final twistItems = [
      for (final t in s.twists)
        PillGridItem(
          data: TwistPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    final hasQuery = widget.searchController.text.trim().isNotEmpty;
    final peopleItems =
        hasQuery ? [...twistItems, ...personItems] : [...personItems, ...twistItems];
    final PillGridSection? peopleSection = peopleItems.isEmpty
        ? null
        : PillGridSection(header: _peopleHeader(), items: peopleItems);

    // Channels (Plot topics + connector channels).
    final channelItems = [
      for (final t in s.channels)
        PillGridItem(
          data: t.kind == ComposeTargetKind.topic
              ? TopicPillData(t.label)
              : ChannelPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    // In normal mode the Channels section is always shown (for the "+ Topic"
    // affordance); in link mode it's shown only when it has link-capable items.
    final PillGridSection? channelSection =
        (_linkMode && channelItems.isEmpty)
            ? null
            : PillGridSection(header: _channelsHeader(), items: channelItems);

    // Private notes (focuses).
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
    final PillGridSection? focusSection = focusItems.isEmpty
        ? null
        : PillGridSection(header: _sectionHeader('Private note'), items: focusItems);

    // Order: link mode → Private notes, then Channels (people hidden).
    // Normal mode → People, Channels, Private notes (unchanged).
    final ordered = _linkMode
        ? <PillGridSection?>[focusSection, channelSection]
        : <PillGridSection?>[peopleSection, channelSection, focusSection];
    return [for (final sec in ordered) ?sec];
  }

  /// Builds the "… More" callback for editable people rows (contact, group,
  /// ad-hoc multi-contact); null for everything else.
  VoidCallback? _rowMoreFor(ComposePillData data) {
    final onRowMore = widget.onRowMore;
    if (onRowMore == null) return null;
    final editable = data is ContactPillData ||
        data is GroupPillData ||
        data is AdHocGroupPillData;
    if (!editable) return null;
    return () async {
      await onRowMore(data);
      if (!_isDisposed) _reload();
    };
  }

  // ─── Header widgets ────────────────────────────────────────────────────────

  /// The "People and twists" section header, with right-aligned "+ Contact"
  /// and "+ Group" ghost buttons (each shown only when its callback is given).
  Widget _peopleHeader() {
    return Builder(
      builder: (context) {
        return Row(
          children: [
            Text('People and twists', style: _headingStyle(context)),
            const Spacer(),
            if (widget.onAddContact != null)
              _headerGhostButton(
                context,
                label: 'Contact',
                onPress: () => _onAddPressed(widget.onAddContact!),
              ),
            if (widget.onAddGroup != null) ...[
              SizedBox(width: context.theme.spacing.xs),
              _headerGhostButton(
                context,
                label: 'Group',
                onPress: () => _onAddPressed(widget.onAddGroup!),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _headerGhostButton(
    BuildContext context, {
    required String label,
    required VoidCallback onPress,
  }) {
    return FButton(
      onPress: onPress,
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
        iconSize: context.theme.iconSizes.xs,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [const Icon(PlotIcon.add), Text(label)],
      ),
    );
  }

  Future<void> _onAddPressed(Future<bool> Function() add) async {
    final created = await add();
    if (created && !_isDisposed) _reload();
  }

  /// The "Channels" section header, with a right-aligned "+ Topic" ghost button
  /// (shown only when [ComposeSectionsView.onCreateTopic] is provided) for
  /// creating a new Plot topic.
  Widget _channelsHeader() {
    return Builder(
      builder: (context) {
        return Row(
          children: [
            Text('Channels', style: _headingStyle(context)),
            const Spacer(),
            if (widget.onCreateTopic != null)
              FButton(
                onPress: _onCreateTopicPressed,
                variant: FButtonVariant.ghost,
                style: ghostSizedStyleDelta(
                  context,
                  textStyle: context.theme.typography.sm,
                  iconSize: context.theme.iconSizes.xs,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
                mainAxisSize: MainAxisSize.min,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Icon(PlotIcon.add),
                    Text('Topic'),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// Opens the create-topic flow and, when a topic was created, reloads the
  /// sections so the new topic surfaces at the top of the Channels list.
  Future<void> _onCreateTopicPressed() async {
    final create = widget.onCreateTopic;
    if (create == null) return;
    final created = await create();
    if (created && !_isDisposed) _reload();
  }

  /// Reloads the current view — re-running the active search, or the at-rest
  /// load when the filter is empty.
  void _reload() {
    if (_linkMode) {
      _loadSections();
      return;
    }
    final query = widget.searchController.text.trim();
    if (query.isEmpty) {
      _loadSections();
    } else {
      _runSearch(query);
    }
  }

  /// A plain section-label widget using the shared heading style.
  Widget _sectionHeader(String text) {
    return Builder(
      builder: (context) => Text(text, style: _headingStyle(context)),
    );
  }

  /// The link chip shown in place of the search field while in link mode:
  /// favicon (or link icon) + title/url + a ✕ to clear and return to the input.
  Widget _buildLinkChip(BuildContext context) {
    final link = widget.pendingLink!;
    final colors = context.theme.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (link.favicon != null)
              LogoImage(
                url: link.favicon!,
                size: 16,
                fallback: const Icon(PlotIcon.link, size: 16),
              )
            else
              const Icon(PlotIcon.link, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                link.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.sm,
              ),
            ),
            Semantics(
              label: 'Clear link',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClearLink,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
                  child: Icon(PlotIcon.close,
                      size: 16, color: colors.mutedForeground),
                ),
              ),
            ),
          ],
        ),
      ),
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          final grid = _gridKey.currentState;
          if (grid == null) return;
          if (!grid.moreHighlighted()) grid.activateHighlighted();
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          final grid = _gridKey.currentState;
          if (grid == null) return;
          if (!grid.moreHighlighted()) grid.activateHighlighted();
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IndexedStack(
            alignment: Alignment.centerLeft,
            sizing: StackFit.loose,
            index: _linkMode ? 1 : 0,
            children: [
              ComposeSearchField(
                controller: widget.searchController,
                focusNode: widget.searchFocusNode,
                hint: 'Start a thread',
                hintDetail: 'with a name, email, channel, or focus',
                autofocus: widget.autofocusSearch && !_linkMode,
                activeListenable: widget.activeListenable,
                onChanged: _onSearchChanged,
                onArrowDown: () => _gridKey.currentState?.moveHighlight(1),
                onArrowUp: () => _gridKey.currentState?.moveHighlight(-1),
                onSubmit: () => _gridKey.currentState?.activateHighlighted(),
                onEscape: null,
              ),
              if (widget.pendingLink != null)
                _buildLinkChip(context)
              else
                const SizedBox.shrink(),
            ],
          ),
          // Match the inter-section gap (PillGrid uses spacing.xl) so the input
          // sits the same distance above the first header as each section does
          // above the next.
          SizedBox(height: spacing.xl),
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
      ),
    );
  }
}
