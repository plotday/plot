import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/compose_search_field.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/connection_compose_field.dart';
import 'package:plot/widget/compose/pill_grid.dart';
import 'package:plot/widget/icon.dart';

/// The step-2 "connection picker" view of the new-thread flow.
///
/// Shown after the user has chosen a recipient from [ComposeSectionsView].
/// Displays the recipient as a removable chip in the search-field leading slot
/// and a [PillGrid] of connections available for that recipient.
///
/// Selecting a connection invokes [onPickConnection]; tapping the chip's ✕
/// or pressing Escape returns to step 1 via [onBack].
class ConnectionPickerView extends StatefulWidget {
  const ConnectionPickerView({
    super.key,
    required this.recipient,
    required this.scrollController,
    required this.searchController,
    required this.searchFocusNode,
    required this.onPickConnection,
    required this.onBack,
    this.autofocusSearch = true,
    this.showBackButton = true,
  });

  /// The chosen recipient from step 1. Drives the leading chip and the roster
  /// passed to [ComposeTargetsBloc.connectionsForRoster].
  final ComposePeopleEntry recipient;

  /// Scroll controller for the pill grid (owned by the host page so it
  /// persists across step round-trips).
  final ScrollController scrollController;

  /// The search text controller. Owned by the page (already cleared on entry
  /// to step 2).
  final TextEditingController searchController;

  /// Focus node for the search field. Owned by the page so the page can
  /// re-focus it on returning to step 1.
  final FocusNode searchFocusNode;

  /// Called when the user picks a connection pill.
  final void Function(ComposeTarget) onPickConnection;

  /// Called when the user taps the recipient chip's ✕, taps the chip itself,
  /// or presses Escape — returns to step 1.
  final VoidCallback onBack;

  /// Whether to autofocus the search field on mount. Enabled by default.
  final bool autofocusSearch;

  /// Whether to render the in-field back chevron (the search field's leading
  /// slot). In single-panel mode the new-thread back lives in the header strip
  /// (UnifiedHeader's new-thread branch, fed by
  /// [ThreadHeaderNotifier.newThreadBack]), so the page passes false to avoid a
  /// redundant in-field chevron; multi-panel has no header back, so it keeps
  /// the in-field one (the default). [onBack] / Escape still return to step 1
  /// either way.
  final bool showBackButton;

  @override
  State<ConnectionPickerView> createState() => _ConnectionPickerViewState();
}

class _ConnectionPickerViewState extends State<ConnectionPickerView> {
  // ─── State ─────────────────────────────────────────────────────────────────

  /// Loaded connections for the recipient. Null while the load is in flight.
  List<ComposeTarget>? _connections;

  /// Monotonic request counter used to discard stale async responses.
  int _requestId = 0;

  bool _isDisposed = false;

  /// Key for the [PillGrid]; drives [PillGridState.moveHighlight] /
  /// [PillGridState.activateHighlighted] as the user navigates the search field.
  final _gridKey = GlobalKey<PillGridState>();

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadConnections();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  // ─── Data loading ──────────────────────────────────────────────────────────

  void _loadConnections() {
    final requestId = ++_requestId;
    final bloc = context.read<ComposeTargetsBloc>();
    bloc
        .connectionsForRoster(
          contacts: widget.recipient.contacts,
          groups: widget.recipient.groups,
          inviteEmails: widget.recipient.inviteEmails,
        )
        .then((connections) {
          if (_isDisposed || requestId != _requestId) return;
          setState(() => _connections = connections);
        })
        .catchError((Object e, StackTrace s) {
          Tracker.captureException(e, s);
        });
  }

  // ─── Section building ──────────────────────────────────────────────────────

  List<PillGridSection> _buildSections() {
    final connections = _connections;
    if (connections == null) return const [];

    final query = widget.searchController.text.toLowerCase();
    // Build (target, pill) pairs once so _pillFor runs exactly once per item.
    final pairs = [for (final t in connections) (t, _pillFor(t))];
    final filtered = query.isEmpty
        ? pairs
        : pairs.where((pair) {
            final pill = pair.$2;
            final t = pair.$1;
            final label = (pill.label ?? t.label).toLowerCase();
            final detail = (pill.detail ?? '').toLowerCase();
            return label.contains(query) || detail.contains(query);
          }).toList();

    if (filtered.isEmpty) return const [];

    return [
      PillGridSection(
        header: _sectionHeader('Connections'),
        items: [
          for (final pair in filtered)
            PillGridItem(
              data: pair.$2,
              onActivate: () => widget.onPickConnection(pair.$1),
            ),
        ],
      ),
    ];
  }

  /// Build the [ConnectionPillData] for a [ComposeTarget].
  ///
  /// Connector targets use [connectionTargetTitle] / [connectionTargetSubtitle]
  /// for label / detail (e.g. "Gmail email" / "kris@plot.day"). Plot note/chat
  /// targets show "Plot" with "Personal" or null for the detail (team names
  /// are baked into [target.label] already).
  ConnectionPillData _pillFor(ComposeTarget t) {
    if (t.kind == ComposeTargetKind.connector && t.target != null) {
      return ConnectionPillData(
        t,
        label: connectionTargetTitle(t.target!),
        detail: connectionTargetSubtitle(t.target!),
      );
    }
    // Plot note / chat — show "Plot" as the label and extract the scope from
    // the bloc-built label's parenthetical (e.g. "Chat (Personal)" → "Personal",
    // "Chat (Acme)" → "Acme", "Chat" → null).
    if (t.kind == ComposeTargetKind.chat || t.kind == ComposeTargetKind.note) {
      return ConnectionPillData(t, label: 'Plot', detail: _scopeOf(t.label));
    }
    return ConnectionPillData(t, label: t.label);
  }

  /// Extracts the text inside the first pair of parentheses in [label], or
  /// returns null if no parentheses are present.
  ///
  /// E.g. "Chat (Personal)" → "Personal"; "Chat" → null.
  String? _scopeOf(String label) {
    final open = label.indexOf('(');
    final close = label.indexOf(')', open + 1);
    if (open < 0 || close < 0) return null;
    return label.substring(open + 1, close).trim();
  }

  // ─── Header widget ─────────────────────────────────────────────────────────

  /// A plain section-label widget. Mirrors the heading style in
  /// [ComposeSectionsView].
  Widget _sectionHeader(String text) {
    return Builder(builder: (context) {
      final style = context.theme.typography.sm.copyWith(
        color: context.theme.colors.mutedForeground,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      );
      return Text(text, style: style);
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;

    // A back button at the start of the input returns to step 1 (the same
    // affordance as Escape, wired through onBack below). Shown only when
    // [showBackButton] is set (multi-panel) — in single-panel the back moves to
    // the header strip; see the field doc.
    final Widget? backButton = widget.showBackButton
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onBack,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Icon(
                PlotIcon.left,
                size: 18,
                color: context.theme.colors.mutedForeground,
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
          hint: 'Select a connection',
          autofocus: widget.autofocusSearch,
          leading: backButton,
          onChanged: () => setState(() {}),
          onArrowDown: () => _gridKey.currentState?.moveHighlight(1),
          onArrowUp: () => _gridKey.currentState?.moveHighlight(-1),
          onSubmit: () => _gridKey.currentState?.activateHighlighted(),
          onEscape: () {
            widget.onBack();
            return true;
          },
        ),
        // The chosen recipient as a static line below the input so the user can
        // see who they are picking a connection for.
        Padding(
          padding: EdgeInsets.only(top: spacing.md, left: spacing.sm),
          child: ComposePill(data: widget.recipient.display),
        ),
        SizedBox(height: spacing.lg),
        Expanded(
          child: _connections == null
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
