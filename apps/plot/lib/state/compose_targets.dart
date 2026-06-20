import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injector/injector.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/draft.dart';
import 'package:plot/util/theme_color.dart' show ThemeColor;
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/compose_target_view.dart';
import 'package:plot/widget/compose/email_parser.dart';
import 'package:plot/widget/connection_targets.dart';

part 'compose_targets_state.dart';

/// One recipient option in section 1 "People & twists": a roster whose
/// connection is chosen later (step 2). [display] drives the pill.
class ComposePeopleEntry extends Equatable {
  const ComposePeopleEntry({
    required this.contacts,
    required this.groups,
    required this.inviteEmails,
    required this.display,
  });
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final List<String> inviteEmails;
  final ComposePillData display;
  bool get hasGroup => groups.isNotEmpty;
  @override
  List<Object?> get props => [contacts, groups, inviteEmails];
}

/// Raw per-draft fields the bloc extracts from a draft thread + its draft note,
/// fed into the pure [buildDraftSummaries]. Kept primitive so the assembly is
/// store-free and unit-testable.
class DraftInput {
  const DraftInput({
    required this.threadId,
    required this.title,
    required this.hasRecipients,
    required this.hasSchedule,
    required this.body,
    required this.hasActions,
    required this.recipientSummary,
    required this.icon,
    required this.sortKey,
    required this.archived,
  });

  final Uuid threadId;
  final String? title;
  final bool hasRecipients;
  final bool hasSchedule;
  final String? body;
  final bool hasActions;

  /// A pre-resolved "To: …" summary used as the label when there is no title
  /// or body. Null when the draft has no recipients.
  final String? recipientSummary;

  /// Optional leading-glyph hint (favicon URL, or null for the default glyph).
  final String? icon;

  /// Recency key for ordering (updatedAt for active, archivedAt for archived).
  final DateTime sortKey;
  final bool archived;
}

/// A draft row ready to render as a picker tile.
class DraftSummary extends Equatable {
  const DraftSummary({
    required this.threadId,
    required this.label,
    required this.detail,
    required this.icon,
    required this.archived,
  });

  final Uuid threadId;
  final String label;
  final String? detail;
  final String? icon;
  final bool archived;

  @override
  List<Object?> get props => [threadId, label, detail, icon, archived];
}

/// Filters [active] and [archived] draft inputs to substantive drafts, orders
/// each group most-recent first, caps [archived] to [archivedLimit], and
/// returns active drafts followed by archived ones.
List<DraftSummary> buildDraftSummaries(
  List<DraftInput> active,
  List<DraftInput> archived, {
  int archivedLimit = 5,
}) {
  bool substantive(DraftInput d) => isSubstantiveDraftFields(
        title: d.title,
        hasRecipients: d.hasRecipients,
        hasSchedule: d.hasSchedule,
        body: d.body,
        hasActions: d.hasActions,
      );

  DraftSummary summary(DraftInput d) => DraftSummary(
        threadId: d.threadId,
        label: draftPrimaryLabel(
          title: d.title,
          bodySnippet: draftBodySnippet(d.body),
          recipientSummary: d.recipientSummary,
        ),
        detail: null,
        icon: d.icon,
        archived: d.archived,
      );

  final activeOut = active.where(substantive).toList()
    ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
  final archivedOut = archived.where(substantive).toList()
    ..sort((a, b) => b.sortKey.compareTo(a.sortKey));

  return [
    ...activeOut.map(summary),
    ...archivedOut.take(archivedLimit).map(summary),
  ];
}

/// Sectioned step-1 data. Each list is limited for the at-rest view;
/// [ComposeTargetsBloc.searchSections] returns the same shape filtered/expanded
/// by query.
class ComposeSections extends Equatable {
  const ComposeSections({
    required this.people,
    required this.twists,
    required this.channels,
    required this.focuses,
    this.drafts = const [],
    this.priorityById = const {},
  });
  final List<ComposePeopleEntry> people;
  final List<ComposeTarget> twists; // kind == twist
  final List<ComposeTarget> channels; // kind == connector, channel != null
  final List<ComposeTarget> focuses; // kind == note (focusNote)

  /// Draft threads to surface as a top "Drafts" section (most-recent first,
  /// then up to 5 most-recently-archived when show-archived is on). Empty in
  /// link mode and during search. See [ComposeTargetsBloc.loadSections].
  final List<DraftSummary> drafts;

  /// The focus priorities by id, snapshotted from the same search context that
  /// produced [focuses]. Carried WITH the sections (rather than read back off
  /// the bloc's live, mutable context) so the view resolves every focus-note
  /// row against a map guaranteed consistent with [focuses]. A reactive
  /// `refresh()` invalidating the bloc's context mid-render must not drop the
  /// "Private note" section to empty — see [ComposeTargetsBloc.loadSections].
  final Map<Uuid, Priority> priorityById;

  @override
  List<Object?> get props => [people, twists, channels, focuses, drafts];
}

/// A distinct compose roster, ignoring team scope and connection. Produced by
/// [dedupePeopleByRoster] and resolved into a [ComposePeopleEntry] by the bloc.
typedef RosterKey = ({
  List<Uuid> contacts,
  List<Uuid> groups,
  List<String> inviteEmails,
});

/// Canonical dedup key for a roster. Stable sort on each dimension so order
/// of inputs doesn't matter; includes invite emails so two rosters differing
/// only by invite address are treated as distinct.
String _rosterKey(
  Iterable<Uuid> contacts,
  Iterable<Uuid> groups,
  Iterable<String> inviteEmails,
) {
  final c = contacts.map((u) => u.toString()).toList()..sort();
  final g = groups.map((u) => u.toString()).toList()..sort();
  final e = inviteEmails.toList()..sort();
  return 'c=${c.join(",")}|g=${g.join(",")}|e=${e.join(",")}';
}

/// Collapses chat/connector-DM targets to distinct rosters, ignoring team scope
/// and connection. First-seen order preserved (callers pass MRU-ordered input).
/// Targets with no roster are skipped.
List<RosterKey> dedupePeopleByRoster(List<ComposeTarget> targets) {
  final seen = <String>{};
  final out = <RosterKey>[];
  for (final t in targets) {
    if (t.contacts.isEmpty && t.groups.isEmpty && t.inviteEmails.isEmpty) {
      continue;
    }
    final key = _rosterKey(t.contacts, t.groups, t.inviteEmails);
    if (!seen.add(key)) continue;
    out.add((
      contacts: t.contacts,
      groups: t.groups,
      inviteEmails: t.inviteEmails,
    ));
  }
  return out;
}

/// Orders people [candidates] into a single true-MRU list. Each candidate is a
/// roster paired with a recency timestamp (epoch ms). Duplicate rosters (the
/// same roster surfaced from more than one source — e.g. an authored thread and
/// the created/used people-MRU) collapse to one entry keeping the **largest**
/// ms. The result is ordered by ms descending; equal-ms ties preserve
/// first-seen order. Pure (no DB) so the MRU semantics are unit-testable.
List<RosterKey> orderPeopleByRecency(
  List<({RosterKey roster, int ms})> candidates,
) {
  // Best ms per roster + first-seen index for a stable tiebreak.
  final bestMs = <String, int>{};
  final firstSeen = <String, int>{};
  final rosterByKey = <String, RosterKey>{};
  var i = 0;
  for (final c in candidates) {
    final key = _rosterKey(c.roster.contacts, c.roster.groups, c.roster.inviteEmails);
    rosterByKey[key] = c.roster;
    firstSeen.putIfAbsent(key, () => i++);
    final existing = bestMs[key];
    if (existing == null || c.ms > existing) bestMs[key] = c.ms;
  }
  final keys = bestMs.keys.toList()
    ..sort((a, b) {
      final byMs = bestMs[b]!.compareTo(bestMs[a]!);
      if (byMs != 0) return byMs;
      return firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  return [for (final k in keys) rosterByKey[k]!];
}

/// The canonical roster identity for a **group** people-entry: the group(s)
/// alone. A group pill renders only the group and its own members, so the
/// incidental per-thread participant [contacts] (and any invite emails) carried
/// in from an authored thread are display-invisible. Keeping them on the entry
/// fragmented the People-list MRU dedup — the same group, filed across many
/// threads with differing participant sets, produced several identical rows
/// (e.g. "Plot Team" appearing four times). Pure (no DB) so it's unit-testable.
RosterKey canonicalGroupRoster(RosterKey r) => (
      contacts: const <Uuid>[],
      groups: r.groups,
      inviteEmails: const <String>[],
    );

/// Chat-capable twist instances (those that opt in via a non-empty `threadType`
/// and aren't connector sources), deduped so a twist that doesn't allow
/// multiple instances surfaces **once** even when the store carries two
/// instances of it. The builtin Plot AI twist, for example, exists both as the
/// user's own instance and as the synthetic system "Plot Team" sender; both
/// expose the same "Plot AI chat" thread type, so without this they render as
/// two identical rows. Twists that allow multiple instances keep every
/// instance. First-seen order preserved. Pure (no DB) so it's unit-testable.
List<TwistInstance> chatTwistInstances(List<TwistInstance> twists) {
  final seenSingletonTwistIds = <BigInt>{};
  final out = <TwistInstance>[];
  for (final t in twists) {
    if (t.isSource || (t.threadType?.isEmpty ?? true)) continue;
    if (!t.multipleInstances && !seenSingletonTwistIds.add(t.twistId)) continue;
    out.add(t);
  }
  return out;
}

/// Sorts named people [matches] (contacts and groups together) alphabetically
/// by display name, case-insensitive, and dedupes by roster keeping the first
/// occurrence. Used by search synthesis to intermix contact and group matches
/// rather than segregating them. Pure (no DB).
List<ComposePeopleEntry> intermixPeopleByName(
  List<({String name, ComposePeopleEntry entry})> matches,
) {
  final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])];
  indexed.sort((a, b) {
    final byName = a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase());
    if (byName != 0) return byName;
    return a.$1.compareTo(b.$1); // stable on equal names
  });
  final seen = <String>{};
  final out = <ComposePeopleEntry>[];
  for (final e in indexed) {
    final entry = e.$2.entry;
    final key = _rosterKey(entry.contacts, entry.groups, entry.inviteEmails);
    if (!seen.add(key)) continue;
    out.add(entry);
  }
  return out;
}

/// Transforms at-rest [sections] for **link mode** (a URL is in the picker):
/// drops People & twists, keeps only link-supporting channels (Plot topics
/// always qualify; connector channels qualify when their
/// [LinkTypeConfig.supportsLinks] is true), and orders both the channels and
/// focuses by [rankByLinkMru] (most-recently-used link destination first).
/// [perSection] caps each surviving list.
ComposeSections linkModeSections(
  ComposeSections sections,
  List<String> Function(List<String> signatures) rankByLinkMru, {
  required int perSection,
}) {
  final linkChannels = sections.channels
      .where((t) =>
          t.kind == ComposeTargetKind.topic ||
          (t.linkType?.supportsLinks ?? false))
      .toList();
  return ComposeSections(
    people: const [],
    twists: const [],
    channels: _orderBySignature(linkChannels, rankByLinkMru).take(perSection).toList(),
    focuses: _orderBySignature(sections.focuses, rankByLinkMru).take(perSection).toList(),
    // Preserve the resolution map so the surviving focuses still resolve.
    priorityById: sections.priorityById,
  );
}

/// Reorders [items] so their [ComposeTarget.signature]s follow the order
/// [rankByLinkMru] returns. Items the ranking doesn't place keep their original
/// relative order (explicit index tiebreak — Dart's sort isn't guaranteed
/// stable on all targets).
List<ComposeTarget> _orderBySignature(
  List<ComposeTarget> items,
  List<String> Function(List<String> signatures) rankByLinkMru,
) {
  final ranked = rankByLinkMru(items.map((t) => t.signature).toList());
  final pos = {for (var i = 0; i < ranked.length; i++) ranked[i]: i};
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final pa = pos[a.$2.signature] ?? 1 << 30;
    final pb = pos[b.$2.signature] ?? 1 << 30;
    if (pa != pb) return pa.compareTo(pb);
    return a.$1.compareTo(b.$1); // tie → preserve original index
  });
  return [for (final e in indexed) e.$2];
}

/// Materializes and caches the step-1 **target picker** list: a globally
/// MRU-ranked list of "ways to create a thread" (a focus-note per
/// recently-used focus, chat-capable twists, every connector
/// connection/channel/DM template, and the specific connection+roster
/// combinations the user has actually used), plus a [search] that synthesizes
/// name- and email-specific targets on demand.
///
/// This is the data substrate behind the picker — no UI. It composes several
/// stores (connections, channels, teams, authored threads) with the
/// [LocalPreferencesBloc] connection-MRU recency, following the bloc pattern
/// used elsewhere in `lib/state`.
///
/// The signature-derivation logic is exposed as **pure** static helpers
/// ([composeSignatureForScanThread], [buildUsedTargetSignatures]) so the
/// ranking is unit-testable without a database — mirroring
/// `Actor.buildShareScan`.
class ComposeTargetsBloc extends Cubit<ComposeTargetsState> {
  ComposeTargetsBloc(this._prefs)
      : super(const ComposeTargetsState(targets: [])) {
    _watchConnections();
  }

  final LocalPreferencesBloc _prefs;

  /// Reactive refresh: the base list is materialized from the connection /
  /// channel / priority stores, so it must rebuild when those change. Without
  /// this, a connection added mid-session only appeared after an app restart
  /// (the page-init [refresh] was the sole trigger). We watch enabled channels
  /// (channel connectors, DMs), twist instances (chat-with-a-twist targets,
  /// connection rename/uninstall), and priorities (the "Private notes" focuses
  /// section + per-connection colour tally) and refresh — debounced so a sync
  /// batch that writes many rows coalesces into one rebuild.
  ///
  /// The priority watch is essential: the shell calls [warm] at mount, which
  /// caches the search context (focuses included) before the priority/role
  /// sync has necessarily landed — and on the path-independent role model
  /// priorities pull *after* roles. Without reacting to priority changes the
  /// cached context never picks up focuses that synced in later, so the
  /// "Private notes" section stays empty until some unrelated channel/twist
  /// change happens to trigger a rebuild.
  StreamSubscription<List<Channel>>? _channelSub;
  StreamSubscription<List<TwistInstance>>? _twistSub;
  StreamSubscription<List<Priority>>? _prioritySub;
  Timer? _refreshDebounce;

  void _watchConnections() {
    _channelSub = Channel.watchAllEnabled().listen(
      (_) => _scheduleRefresh(),
      onError: (Object e, StackTrace s) => Tracker.captureException(e, s),
    );
    _twistSub = TwistInstance.watch().listen(
      (_) => _scheduleRefresh(),
      onError: (Object e, StackTrace s) => Tracker.captureException(e, s),
    );
    // watchRaw skips the active/unread enrichment (and its threads-table
    // scans) — we only need to know the priority *set* changed.
    _prioritySub = Priority.watchRaw().listen(
      (_) => _scheduleRefresh(),
      onError: (Object e, StackTrace s) => Tracker.captureException(e, s),
    );
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (isClosed || !Injector.appInstance.exists<Store>()) return;
      unawaited(refresh().catchError(
        (Object e, StackTrace s) => Tracker.captureException(e, s),
      ));
    });
  }

  @override
  Future<void> close() {
    _refreshDebounce?.cancel();
    _channelSub?.cancel();
    _twistSub?.cancel();
    _prioritySub?.cancel();
    return super.close();
  }

  /// How many recent authored threads to scan for used combinations. The
  /// base list stays conservative (recently-used combos + one fresh template
  /// per connection); the full channel/contact space is reachable via
  /// [search]. Mirrors the share-scan window in `actor.dart`.
  static const int _authoredScanWindow = 80;

  /// Cap on the source pool loaded by [searchSections] before filtering.
  /// Exceeding this is implausible given the MRU scan window ([_authoredScanWindow]).
  static const int _kSearchPoolLimit = 1000;

  /// Rebuild the cached base list from the stores + MRU recency. Call on the
  /// inputs that change it: connections/channels syncing, team membership
  /// changing, and after recording a created thread (see [recordTarget],
  /// which also fast-paths a prepend so the next open reflects it instantly).
  Future<void> refresh() async {
    // The base list is materialized from the store, which isn't registered in
    // the injector until a user is signed in and the DB is open (and is torn
    // down on sign-out). Touching it then throws `The type "Store" is not
    // defined!` from the injector. Mirrors the guard in [_scheduleRefresh] and
    // covers the boot path ([warm] runs at shell mount, before sign-in).
    if (isClosed || !Store.isAvailable) return;
    // The cached search context is derived from the same stores this rebuilds,
    // so drop it first and let [_materializeBaseList] repopulate it from fresh
    // data; subsequent per-keystroke searches then reuse that fresh context.
    _invalidateSearchContext();
    final targets = await _materializeBaseList();
    // _materializeBaseList already awaited _searchContextFor(), so this returns
    // the freshly-cached context (no extra queries).
    final ctx = await _searchContextFor();
    // A reactive refresh can resolve after the bloc is closed (sign-out, the
    // page disposing): emitting then throws.
    if (isClosed) return;
    emit(state.copyWith(targets: _toViews(targets, ctx)));
  }

  /// Pre-builds the step-1 picker's at-rest data (and the shared, cached
  /// search context behind it) so the first [loadSections] after the page
  /// mounts is fast. NewThreadPage is always mounted in multi-panel layouts,
  /// so this work happens at app load there; in single-panel the page isn't
  /// mounted until the user taps "New", so the single-panel shell calls this
  /// on mount to close that gap. The result is discarded — only the cached
  /// context and warmed entity caches matter — and it's a no-op once warm
  /// ([_searchContextFor] returns the cached context).
  Future<void> warm() async {
    await loadSections();
  }

  /// Filter + synthesize targets for [query].
  ///
  /// - Empty → the cached base list.
  /// - Email (per [EmailParser]) → a Plot **Chat** option per scope (Personal +
  ///   each team) that starts a chat with that address (inviting it by email
  ///   when it's a brand-new address), pinned above every address-capable
  ///   connection, with any connection previously used for *that address* first.
  /// - Otherwise plain-text filter of the base list by label, AND name-match
  ///   synthesis: for each correspondent the user has **authored/replied**
  ///   with whose name matches, the most-recent contact/DM/address
  ///   combinations used with them (even outside the base slice).
  ///
  /// Synthesis is intentionally not cached — it runs against the live stores
  /// per query, on top of the cached base list.
  Future<List<ComposeTargetView>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return state.targets; // already views

    final ctx = await _searchContextFor();
    final recipients = EmailParser.parseRecipients(trimmed);
    if (recipients.isNotEmpty) {
      return _searchByRecipients(recipients);
    }

    final lower = trimmed.toLowerCase();
    final filtered = state.targets
        .where((v) =>
            v.target.label.toLowerCase().contains(lower) ||
            v.header.toLowerCase().contains(lower))
        .map((v) => v.target)
        .toList();
    final byName = await _searchByName(trimmed);
    return _toViews(_dedupeBySignature([...filtered, ...byName]), ctx);
  }

  /// Record that the user just created a thread for [target]: bump its
  /// signature in the connection MRU (optionally biased toward [priorityId])
  /// AND prepend/bump it in the cached list so the next New thread reflects it
  /// immediately, without waiting for a full [refresh].
  Future<void> recordTarget(ComposeTarget target, {String? priorityId}) async {
    await _prefs.recordConnectionUsage(
      channelKey: target.signature,
      priorityId: priorityId,
    );
    prependToCache(target);
  }

  /// Record that the user just created/used a people roster outside an authored
  /// thread (e.g. added a contact or created a group from the picker header).
  /// Bumps it to the top of the People-list MRU. Pre-warms the contact/group
  /// caches so the very next [loadSections] resolves a just-created entity that
  /// hasn't been pulled yet. Idempotent on the roster key.
  Future<void> recordPersonUsage({
    required List<Uuid> contacts,
    required List<Uuid> groups,
    required List<String> inviteEmails,
  }) async {
    final key = _rosterKey(contacts, groups, inviteEmails);
    final now = DateTime.now().millisecondsSinceEpoch;
    _createdPeopleMru[key] = (
      roster: (contacts: contacts, groups: groups, inviteEmails: inviteEmails),
      ms: now,
    );
    if (_createdPeopleMru.length > _maxCreatedPeopleMru) {
      final oldestKey = _createdPeopleMru.entries
          .reduce((a, b) => a.value.ms <= b.value.ms ? a : b)
          .key;
      _createdPeopleMru.remove(oldestKey);
    }
    // Warm caches so the synchronous _peopleEntryFor resolve sees a just-created
    // (un-pulled) contact/group. getOne is a cache hit after the first read;
    // swallow not-found (a reconciled/removed id is simply dropped at render).
    for (final cid in contacts) {
      try {
        await Actor.getOne(ActorId.fromUuid(cid));
      } catch (_) {/* unresolved id is dropped at render time */}
    }
    for (final gid in groups) {
      await Group.getOne(gid);
    }
  }

  /// Focus suggestion for the two-step compose flow: the priority ids of
  /// recent authored threads whose roster overlaps [contacts]/[groups], most-
  /// recent first and deduped. The first id is the MRU-top focus the compose
  /// surface pre-selects; the focus picker lists focuses in this order.
  ///
  /// With an empty roster (a Note, or a no-contact connector target) there is
  /// nothing roster-specific to rank by, so this returns an empty list and the
  /// caller falls back to [rankFocusesGlobal].
  Future<List<Uuid>> rankFocusesForRoster({
    required List<Uuid> contacts,
    required List<Uuid> groups,
  }) async {
    if (contacts.isEmpty && groups.isEmpty) return const [];
    final contactSet = contacts.toSet();
    final groupSet = groups.toSet();

    final selfIds =
        Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    if (selfIds.isEmpty) return const [];
    final rows = await _authoredThreadRows(selfIds, _authoredScanWindow);

    final seen = <Uuid>{};
    final ordered = <Uuid>[];
    for (final row in rows) {
      final rowContacts = (row.contacts ?? const <Uuid>[]).toSet();
      final rowGroups = (row.groups ?? const <Uuid>[]).toSet();
      final overlaps = rowContacts.intersection(contactSet).isNotEmpty ||
          rowGroups.intersection(groupSet).isNotEmpty;
      if (!overlaps) continue;
      if (seen.add(row.priorityId)) ordered.add(row.priorityId);
    }
    return ordered;
  }

  /// Global focus MRU: the priority ids the user most recently filed *any*
  /// authored thread into, most-recent first and deduped — ignoring roster.
  ///
  /// Used by the two-step compose flow as the focus suggestion for no-roster
  /// targets (a Note, or a no-contact connector target like Google Tasks),
  /// where [rankFocusesForRoster] has nothing roster-specific to rank by. The
  /// first id is the MRU-top focus the compose surface pre-selects, so step 2
  /// always lands on a concrete focus (Auto-organize is gone). Reuses the same
  /// recently-authored-thread window as the roster ranking.
  Future<List<Uuid>> rankFocusesGlobal() async {
    final selfIds =
        Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    if (selfIds.isEmpty) return const [];
    final rows = await _authoredThreadRows(selfIds, _authoredScanWindow);

    final seen = <Uuid>{};
    final ordered = <Uuid>[];
    for (final row in rows) {
      if (seen.add(row.priorityId)) ordered.add(row.priorityId);
    }
    return ordered;
  }

  /// Prepend [target] to the cached list (or move it to the front if a target
  /// with the same signature is already present). Exposed for the submit path
  /// and unit tests.
  void prependToCache(ComposeTarget target) {
    // Resolve the view against the still-warm context before invalidating, so
    // a fast-path prepend before the next refresh still gets a header/tint.
    final ctx = _searchContext;
    // Recording a created thread changes the authored-thread history the
    // search context is built from, so drop the cache; the next search (or
    // refresh) rebuilds it.
    _invalidateSearchContext();
    final view = _toView(target, ctx);
    final next = <ComposeTargetView>[
      view,
      ...state.targets.where((v) => v.target.signature != target.signature),
    ];
    emit(state.copyWith(targets: next));
  }

  // --- View resolution -----------------------------------------------------

  /// Resolve a [ComposeTarget] into its presentation view using the cached
  /// [ctx] (header text, focus tint, disambiguated recipients, focus object).
  /// Falls back to neutral defaults when [ctx] is null (e.g. a prepend before
  /// the next refresh).
  ComposeTargetView _toView(ComposeTarget t, _ComposeSearchContext? ctx) {
    final header = _headerFor(t, ctx);
    final ThemeColor color;
    Priority? focus;
    if (t.kind == ComposeTargetKind.note && t.priorityId != null) {
      focus = ctx?.priorityById[t.priorityId!];
      color = focus?.displayColor ?? const ThemeColor.defaultColor();
    } else {
      color = ctx?.colorByConnection[connectionColorKey(t)] ??
          const ThemeColor.defaultColor();
    }
    return ComposeTargetView(
      target: t,
      header: header,
      headerColor: color,
      recipients: _recipientsFor(t, ctx),
      focusPriority: focus,
    );
  }

  List<ComposeTargetView> _toViews(
    List<ComposeTarget> targets,
    _ComposeSearchContext? ctx,
  ) =>
      [for (final t in targets) _toView(t, ctx)];

  /// Line-1 connection header text.
  String _headerFor(ComposeTarget t, _ComposeSearchContext? ctx) {
    switch (t.kind) {
      case ComposeTargetKind.connector:
        final target = t.target!;
        final showAccount = (ctx?.connectionCount(target) ?? 1) > 1;
        final account = target.accountName;
        return (showAccount && account != null && account.isNotEmpty)
            ? '${target.connectorName} · $account'
            : target.connectorName;
      case ComposeTargetKind.twist:
        // Header = twist name (+ scope suffix); the content line shows the
        // thread type (t.label).
        return t.twistHeader ?? t.label;
      case ComposeTargetKind.topic:
        // Topics surface only as pills (TopicPillData) in the sections view,
        // never through the flat target views, so this header is effectively
        // unused; keep a sensible value for search-by-header matching.
        return 'Topic';
      case ComposeTargetKind.chat:
      case ComposeTargetKind.note:
        final hasTeams = ctx?.hasTeams ?? false;
        if (!hasTeams) return 'Plot';
        final scope = t.teamId == null
            ? 'Personal'
            : (ctx?.teamNames[t.teamId] ?? 'Team');
        return 'Plot · $scope';
    }
  }

  /// People rows (Plot chat + connector DM): disambiguated recipients.
  List<RecipientDisplay> _recipientsFor(
      ComposeTarget t, _ComposeSearchContext? ctx) {
    final isPeople = t.kind == ComposeTargetKind.chat ||
        (t.kind == ComposeTargetKind.connector && (t.target?.isDmType ?? false));
    if (!isPeople) return const [];
    final byName =
        ctx?.nameToEmailsByConnection[connectionColorKey(t)] ?? const {};
    final inputs = <RecipientInput>[];
    for (final cId in t.contacts) {
      final actor = Actor.fromCache(ActorId.fromUuid(cId));
      inputs.add((
        name: actor?.nameOrEmail ?? '',
        email: actor?.email,
        actorId: ActorId.fromUuid(cId),
      ));
    }
    // Groups shared on the thread render by name (no avatar — a group isn't an
    // actor). The group cache holds the full set after the startup pull, so
    // fromCache resolves; an uncached group is skipped rather than shown blank.
    for (final gId in t.groups) {
      final group = Group.fromCache(gId);
      if (group != null) {
        inputs.add((name: group.name, email: null, actorId: null));
      }
    }
    for (final encoded in t.inviteEmails) {
      final inv = InviteAddress.parse(encoded);
      inputs
          .add((name: inv.name ?? inv.email, email: inv.email, actorId: null));
    }
    return resolveRecipientDisplays(
        recipients: inputs, nameToEmailsForConnection: byName);
  }

  // --- Query-independent search context ------------------------------------

  /// Cached, query-independent inputs shared by [_materializeBaseList] and the
  /// per-keystroke search synthesis. Built once and reused until invalidated.
  _ComposeSearchContext? _searchContext;

  /// In-flight context build, so concurrent callers (e.g. a [refresh] and the
  /// first keystroke after open) share one build instead of each issuing the
  /// underlying team/connection/authored-thread queries.
  Future<_ComposeSearchContext>? _contextBuild;

  /// Monotonic token used to discard a stale in-flight build whose result a
  /// later [_invalidateSearchContext] has superseded.
  int _contextToken = 0;

  /// In-memory, session-scoped people-MRU for rosters created/used outside an
  /// authored thread — a "+ Contact" / "+ Group" that has no thread yet. Keyed
  /// by [_rosterKey]; value carries the roster (to resolve a pill) and the
  /// recency ms. Merged (by max ms) with authored-thread recency in
  /// [loadSections] so creation bumps the entry to the top of the People list.
  /// Bounded; oldest entries are evicted past the cap.
  final Map<String, ({RosterKey roster, int ms})> _createdPeopleMru = {};
  static const int _maxCreatedPeopleMru = 50;

  /// Returns the cached search context, building (and caching) it on first use.
  Future<_ComposeSearchContext> _searchContextFor() {
    final cached = _searchContext;
    if (cached != null) return Future.value(cached);
    final existing = _contextBuild;
    if (existing != null) return existing;
    final token = ++_contextToken;
    final build = _buildSearchContext().then(
      (ctx) {
        // Only publish if a concurrent invalidate hasn't superseded this build.
        if (token == _contextToken) {
          _searchContext = ctx;
          _contextBuild = null;
        }
        return ctx;
      },
      onError: (Object e, StackTrace s) {
        if (token == _contextToken) _contextBuild = null;
        Error.throwWithStackTrace(e, s);
      },
    );
    _contextBuild = build;
    return build;
  }

  /// Drop the cached context (and supersede any in-flight build) so the next
  /// [_searchContextFor] rebuilds from fresh stores.
  void _invalidateSearchContext() {
    _searchContext = null;
    _contextBuild = null;
    _contextToken++;
  }

  /// Loads the query-independent pieces every base-list/search pass needs:
  /// active teams, the connector create-targets (with per-connector counts and
  /// a signature index), and the recent authored-thread roster scan.
  Future<_ComposeSearchContext> _buildSearchContext() async {
    // These three reads are independent, so issue them concurrently rather
    // than awaiting in series — on a cold open (single-panel, first "New")
    // this chain is the bulk of the wait, and `_scanAuthoredThreads` alone
    // runs a threads + links query.
    final (teams, createTargets, scan) = await (
      TeamUser.getActive(),
      loadCreateTargets(),
      _scanAuthoredThreads(),
    ).wait;

    // Warm the Actor cache so the synchronous Actor.fromCache lookups below
    // (the disambiguation tally) and in the used-combo rendering resolve on a
    // cold open. Without this, a fresh/just-synced account leaves roster
    // contacts uncached, so the used Gmail/Chat combos collapsed to bare
    // connector/chat labels instead of showing the people. One query on the
    // refresh path (not per-keystroke) — the same fetch the share picker uses.
    if (scan.threads.any((st) => st.contacts.isNotEmpty)) {
      await Actor.get(types: [ActorType.user, ActorType.contact]);
    }

    final teamNames = {for (final t in teams) t.teamId: t.teamName};
    // Connection count per connector package (same twistId = same connector),
    // so the account-label parenthetical shows only when >1 connection.
    final connectionCountByTwistId = <BigInt, int>{};
    final seenInstances = <TwistInstanceId>{};
    for (final t in createTargets) {
      if (seenInstances.add(t.twist.id)) {
        connectionCountByTwistId[t.twist.twistId] =
            (connectionCountByTwistId[t.twist.twistId] ?? 0) + 1;
      }
    }
    // Index templates by signature so used combos can reuse the resolved
    // CreateTarget (and so we can dedupe templates already covered by a combo).
    final templateBySignature = <String, CreateTarget>{
      for (final t in createTargets) t.key: t,
    };

    // Per connectionColorKey -> priorityId counts (colour tally). Plot threads
    // (no primary link) are keyed per scope so a work team's dominant colour
    // stays distinct from personal; connector threads key by the connection.
    final connKeyPriorityCounts = <String, Map<Uuid, int>>{};
    // Focus-note ordering: focuses seen on Plot (no-link) threads, MRU-first,
    // each with its most-common Plot scope.
    final focusScopeCounts = <Uuid, Map<BigInt?, int>>{};
    final focusOrder = <Uuid>[];
    // Disambiguation: per connectionColorKey, lowercased name -> ordered addrs.
    final connKeyNameAddrs = <String, Map<String, List<String>>>{};

    for (final st in scan.threads) {
      final isPlot = st.primaryLink == null;
      final connKey = isPlot
          ? 'plot:${st.teamId?.toString() ?? 'personal'}'
          : 'conn:${st.primaryLink!.instanceId}';
      (connKeyPriorityCounts[connKey] ??= {})
          .update(st.priorityId, (n) => n + 1, ifAbsent: () => 1);

      if (isPlot) {
        if (!focusOrder.contains(st.priorityId)) focusOrder.add(st.priorityId);
        (focusScopeCounts[st.priorityId] ??= {})
            .update(st.teamId, (n) => n + 1, ifAbsent: () => 1);
      }

      // Disambiguation uses the already-warm Actor cache (fromCache); uncached
      // contacts are skipped (their rows just show a bare name — safe). Do NOT
      // add an all-contacts fetch here; that would slow context builds.
      for (final cId in st.contacts) {
        final actor = Actor.fromCache(ActorId.fromUuid(cId));
        final name = actor?.name;
        final email = actor?.email;
        if (name == null || name.isEmpty || email == null) continue;
        final byName = connKeyNameAddrs[connKey] ??= {};
        final list = byName[name.toLowerCase()] ??= [];
        if (!list.contains(email.toLowerCase())) list.add(email.toLowerCase());
      }
    }

    // Load all the user's focuses (one bounded query; getRaw skips the
    // active/unread enrichment we don't need — we only read
    // displayColor/root/id). Every focus is offered as a focus-note target,
    // and the per-connection colour tally resolves from the same list.
    final priorities = await Priority.getRaw(order: PriorityOrder.nested);
    final priorityById = {for (final p in priorities) p.id: p};
    final colorByConnection = <String, ThemeColor>{
      for (final e in connKeyPriorityCounts.entries)
        e.key: priorityById[_topByCount(e.value)]?.displayColor ??
            const ThemeColor.defaultColor(),
    };
    // Focus-note targets: every focus. The ones the user has actually filed
    // Plot threads into come first (MRU, scoped to their most-common Plot
    // team/personal); the remaining focuses (no Plot history yet) follow in the
    // natural focus order, defaulting to Personal scope. Inbox/root is included
    // so there's always a plain-note path.
    final scanFocusIds = focusOrder.toSet();
    final focusNoteOrder = <({Uuid priorityId, BigInt? teamId})>[
      for (final pid in focusOrder)
        if (priorityById[pid] != null)
          (priorityId: pid, teamId: _topScope(focusScopeCounts[pid]!)),
      for (final p in priorities)
        if (!scanFocusIds.contains(p.id)) (priorityId: p.id, teamId: null),
    ];

    return _ComposeSearchContext(
      teams: teams,
      hasTeams: teams.isNotEmpty,
      teamNames: teamNames,
      createTargets: createTargets,
      connectionCountByTwistId: connectionCountByTwistId,
      templateBySignature: templateBySignature,
      scan: scan,
      colorByConnection: colorByConnection,
      priorityById: priorityById,
      nameToEmailsByConnection: connKeyNameAddrs,
      focusNoteOrder: focusNoteOrder,
    );
  }

  // --- Base-list materialization -------------------------------------------

  Future<List<ComposeTarget>> _materializeBaseList() async {
    final ctx = await _searchContextFor();
    final scan = ctx.scan;

    // 1. Used combinations from recent authored threads, most-recent first.
    final usedSignatures = buildUsedTargetSignatures(scan.threads);
    // Re-rank by recorded MRU recency (a combo used in many old threads should
    // still sort by when it was last *chosen*); thread order breaks ties for
    // combos with no recorded use yet.
    final rankedUsed = _prefs.rankSignaturesByMru(signatures: usedSignatures);

    final used = <ComposeTarget>[];
    for (final sig in rankedUsed) {
      final st = scan.bySignature[sig];
      if (st == null) continue;
      final target = _composeTargetForScanThread(
        st,
        templateBySignature: ctx.templateBySignature,
        connectionCount: ctx.connectionCount,
        hasTeams: ctx.hasTeams,
        teamNames: ctx.teamNames,
      );
      if (target != null) used.add(target);
    }

    // 2. Always-available templates not already represented by a used combo.
    final templates = <ComposeTarget>[];
    // Focus-note targets: one per focus (the ones the user files Plot threads
    // into first, MRU; then the rest), each with its most-common Plot scope.
    // The focus title becomes the label so the rows stay distinct (the display
    // dedup collapses same-label rows) and are searchable by focus name.
    for (final f in ctx.focusNoteOrder) {
      templates.add(ComposeTarget.focusNote(
        priorityId: f.priorityId,
        teamId: f.teamId,
        title: ctx.priorityById[f.priorityId]?.displayTitle ?? 'Note',
      ));
    }
    // Twist targets (chat with a twist).
    templates.addAll(await _twistTargets(ctx));
    // One fresh template per CHANNEL connection link type. DM/address
    // connectors (Gmail, Slack DMs, …) only make sense with a recipient, so a
    // bare "Gmail" template is noise — those connectors surface via used-combos
    // (carrying contacts) or by typing a name/email in search. Channel
    // connectors keep their per-channel template (the channel is the content).
    for (final t in ctx.createTargets) {
      if (t.isDmType) continue;
      templates.add(ComposeTarget.connector(
        t,
        connectionCount: ctx.connectionCount(t),
        channelDetail: t.channel?.title,
      ));
    }

    return _dedupeForDisplay([...used, ...templates]);
  }

  /// Twist targets (chat with a twist). Only twists that opt in via a
  /// non-empty `threadType` and aren't source/connector instances are chat
  /// targets — connectors are also twist_instances, so without this filter a
  /// connection (e.g. Gmail) would wrongly appear as a "chat with a twist"
  /// row. Matches the `chatTwists` filter in connection_chip.dart.
  Future<List<ComposeTarget>> _twistTargets(_ComposeSearchContext ctx) async {
    final twists = await TwistInstance.get();
    final chatTwists = chatTwistInstances(twists);
    return [
      for (final twist in chatTwists)
        ComposeTarget.twist(
          twist,
          allInstances: twists,
          teamName: twist.teamId == null ? null : ctx.teamNames[twist.teamId],
        ),
    ];
  }

  /// Plot **topic** targets the user can post to, most-recently-active first.
  /// Each becomes a [ComposeTarget.topic] that, when picked, files the new
  /// thread into the topic (sets `thread.topic_id`). Ordered by `updatedAt`
  /// descending so a freshly-created topic (which just synced) leads the list.
  Future<List<ComposeTarget>> _topicTargets() async {
    final rows = await Topic.getPostable();
    // Most-recently-active first, so a just-created topic leads the list.
    rows.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [
      for (final t in rows)
        ComposeTarget.topic(
          topicId: t.id,
          name: t.name,
          teamId: t.teamId == null ? null : BigInt.from(t.teamId!),
        ),
    ];
  }

  // --- Sectioned step-1 producers ------------------------------------------

  /// Step-1 at-rest sections. People = MRU rosters (deduped) classified into
  /// contact/group/ad-hoc pills; twists/channels/focuses reuse existing
  /// builders.
  Future<ComposeSections> loadSections({
    int perSection = 8,
    bool linkMode = false,
    Uuid? currentFocusId,
    bool includeArchivedDrafts = false,
  }) async {
    // See [refresh]: before sign-in / after sign-out the store is unavailable,
    // so there is nothing to build. [warm] (called from the shell at boot)
    // reaches here when the app paints signed-out — without this guard the
    // store access below throws `The type "Store" is not defined!`.
    if (!Store.isAvailable) {
      return const ComposeSections(
        people: [],
        twists: [],
        channels: [],
        focuses: [],
      );
    }
    final drafts = linkMode
        ? const <DraftSummary>[]
        : await _loadDraftSummaries(includeArchived: includeArchivedDrafts);

    final ctx = await _searchContextFor();
    final scan = ctx.scan;

    final people = <ComposePeopleEntry>[];
    if (!linkMode) {
      // True MRU: gather candidate rosters with a recency timestamp from two
      // sources, merged by max — authored threads (use, already persisted) and
      // the in-memory created/used people-MRU (a "+ Contact"/"+ Group" with no
      // thread yet). Either source bumps a roster toward the top.
      final candidates = <({RosterKey roster, int ms})>[];
      for (final st in scan.threads) {
        if (st.contacts.isEmpty && st.groups.isEmpty) continue;
        candidates.add((
          roster: (
            contacts: st.contacts,
            groups: st.groups,
            inviteEmails: const <String>[],
          ),
          ms: st.recencyMs,
        ));
      }
      // Add the in-memory pinned rosters ("+ Contact"/"+ Group" with no thread
      // yet) to the candidate pool.
      for (final e in _createdPeopleMru.values) {
        candidates.add((roster: e.roster, ms: e.ms));
      }
      // Warm the Actor/Group caches the synchronous resolve below reads
      // (_peopleEntryFor / _groupPeopleEntry use *fromCache* only), deduped
      // across candidates so a group shared by many threads — or a contact on
      // many rosters — is touched once instead of re-warmed per occurrence.
      await _warmRostersForResolve(candidates);

      // Resolve in MRU order, dropping unresolvable/collapsed rosters, capped.
      final seenRosters = <String>{};
      for (final roster in orderPeopleByRecency(candidates)) {
        final entry = _peopleEntryFor(roster);
        if (entry == null) continue;
        if (!seenRosters
            .add(_rosterKey(entry.contacts, entry.groups, entry.inviteEmails))) {
          continue;
        }
        people.add(entry);
        if (people.length >= perSection) break;
      }
    }

    final twists = await _twistTargets(ctx);

    // Plot topics (Plot-only channels) lead the Channels section, most-recently
    // active first, so a just-created topic surfaces at the top.
    final topicTargets = await _topicTargets();
    final allChannels = <ComposeTarget>[
      ...topicTargets,
      for (final t in ctx.createTargets)
        if (!t.isDmType)
          ComposeTarget.connector(
            t,
            connectionCount: ctx.connectionCount(t),
            channelDetail: t.channel?.title,
          ),
    ];

    // The "Private notes" section leads with the focus the user is currently
    // viewing (when they're in a focus — not the Everything view), so the most
    // likely note destination is the first option. It's MOVED to the front of
    // the MRU order, never duplicated lower down. A current focus that no
    // longer resolves (e.g. just archived) is ignored.
    var focusOrder = ctx.focusNoteOrder;
    if (currentFocusId != null && ctx.priorityById.containsKey(currentFocusId)) {
      BigInt? pinnedTeamId;
      final rest = <({Uuid priorityId, BigInt? teamId})>[];
      for (final f in focusOrder) {
        if (f.priorityId == currentFocusId) {
          pinnedTeamId = f.teamId;
        } else {
          rest.add(f);
        }
      }
      focusOrder = [
        (priorityId: currentFocusId, teamId: pinnedTeamId),
        ...rest,
      ];
    }

    final allFocuses = <ComposeTarget>[
      for (final f in focusOrder)
        ComposeTarget.focusNote(
          priorityId: f.priorityId,
          teamId: f.teamId,
          title: ctx.priorityById[f.priorityId]?.displayTitle ?? 'Note',
        ),
    ];

    if (linkMode) {
      // Link mode: only Private notes + link-supporting Channels, link-MRU
      // ordered. People & twists are hidden (links-to-contacts is future work).
      return linkModeSections(
        ComposeSections(
          people: const [],
          twists: const [],
          channels: allChannels,
          focuses: allFocuses,
          priorityById: ctx.priorityById,
        ),
        (sigs) => _prefs.rankByLinkMru(signatures: sigs),
        perSection: perSection,
      );
    }

    return ComposeSections(
      people: people,
      twists: twists.take(perSection).toList(),
      channels: allChannels.take(perSection).toList(),
      focuses: allFocuses.take(perSection).toList(),
      drafts: drafts,
      priorityById: ctx.priorityById,
    );
  }

  /// Builds the draft summaries for the picker: substantive active drafts
  /// (most-recent first) plus, when [includeArchived], up to 5 most-recently
  /// archived drafts. Returns [] when the store is unavailable.
  Future<List<DraftSummary>> _loadDraftSummaries({
    required bool includeArchived,
  }) async {
    if (!Store.isAvailable) return const [];

    Future<DraftInput> toInput(Thread t, {required bool archived}) async {
      final note = await Note.getDraftByActivity(t.id);
      final hasRecipients =
          t.contacts.isNotEmpty || t.groups.isNotEmpty || t.inviteEmails.isNotEmpty;
      return DraftInput(
        threadId: t.id,
        title: t.title,
        hasRecipients: hasRecipients,
        hasSchedule: t.at != null || t.on != null,
        body: note?.content,
        hasActions: note?.actions?.isNotEmpty ?? false,
        recipientSummary: _draftRecipientSummary(t),
        icon: (t.icon != null && t.icon!.startsWith('http')) ? t.icon : null,
        sortKey: archived ? (t.archivedAt ?? t.updatedAt) : t.updatedAt,
        archived: archived,
      );
    }

    final activeThreads = await Thread.get(draft: true, archived: false);
    final active = [
      for (final t in activeThreads) await toInput(t, archived: false),
    ];

    var archived = const <DraftInput>[];
    if (includeArchived) {
      final archivedThreads = await Thread.get(draft: true, archived: true);
      archived = [
        for (final t in archivedThreads) await toInput(t, archived: true),
      ];
    }

    return buildDraftSummaries(active, archived);
  }

  /// A short "To: …" summary of a draft's recipients, resolved from the warm
  /// Actor/Group caches. Null when the draft has no recipients.
  String? _draftRecipientSummary(Thread t) {
    final names = <String>[];
    for (final c in t.contacts) {
      final a = Actor.fromCache(ActorId.fromUuid(c));
      final n = a?.name ?? a?.email;
      if (n != null && n.isNotEmpty) names.add(n);
    }
    for (final g in t.groups) {
      final grp = Group.fromCache(g);
      if (grp != null && grp.name.isNotEmpty) names.add(grp.name);
    }
    names.addAll(t.inviteEmails);
    if (names.isEmpty) return null;
    final shown = names.take(3).join(', ');
    final extra = names.length - 3;
    return extra > 0 ? 'To: $shown +$extra' : 'To: $shown';
  }

  /// Build a [ComposePeopleEntry] for a formal group from an already-resolved
  /// [GroupRow], dropping non-inviteable members from the preview. Shared by
  /// [_peopleEntryFor] (cache path) and search synthesis (row path), so a
  /// just-created/un-cached group still resolves in search.
  ComposePeopleEntry _groupPeopleEntry(GroupRow g, RosterKey r) {
    final members = [
      for (final id in (g.memberContactIds ?? const <Uuid>[]))
        Actor.fromCache(ActorId.fromUuid(id)),
    ].whereType<Actor>().where((a) => a.inviteable).toList();
    // The entry's identity is the group itself, not the authored thread's
    // incidental participants — so every thread filed to the group collapses to
    // one People row (and picking it composes to the group, which expands to its
    // members at dispatch).
    final roster = canonicalGroupRoster(r);
    return ComposePeopleEntry(
      contacts: roster.contacts,
      groups: roster.groups,
      inviteEmails: roster.inviteEmails,
      display: GroupPillData(g, members),
    );
  }

  /// Warms the Actor/Group caches that the synchronous people-entry resolve
  /// ([_peopleEntryFor] / [_groupPeopleEntry]) reads via `fromCache`, deduped
  /// across [candidates]. In the common case this issues **no** queries:
  /// groups are fully cached at startup and the context build bulk-loads
  /// contacts, so every `fromCache` hits — this loop only reaches the DB for a
  /// genuinely un-cached (e.g. just-created/un-synced) entity. Member contacts
  /// of each candidate group are warmed too, so [_groupPeopleEntry] can show a
  /// correct member count.
  Future<void> _warmRostersForResolve(
    List<({RosterKey roster, int ms})> candidates,
  ) async {
    final groupIds = <Uuid>{};
    final contactIds = <Uuid>{};
    for (final c in candidates) {
      groupIds.addAll(c.roster.groups);
      contactIds.addAll(c.roster.contacts);
    }
    // Resolve each distinct group once, collecting its members to warm too.
    for (final gid in groupIds) {
      final g = Group.fromCache(gid) ?? await Group.getOne(gid);
      if (g != null) contactIds.addAll(g.memberContactIds ?? const <Uuid>[]);
    }
    // Warm any not-yet-cached contact (group members + pinned-roster contacts).
    // Cache hits cost nothing; only un-cached ids reach the DB.
    for (final cid in contactIds) {
      final aid = ActorId.fromUuid(cid);
      if (Actor.fromCache(aid) != null) continue;
      try {
        await Actor.getOne(aid);
      } catch (_) {/* contact not present locally — dropped at resolve */}
    }
  }

  /// Warm the in-memory [Actor] cache for [g]'s member contacts so a
  /// subsequent (synchronous) [_groupPeopleEntry] resolves them. The cache is
  /// lazily populated (startup loads only self + twists), and neither the
  /// search nor the at-rest path otherwise loads a group's members — so the
  /// member count renders 0 for any group whose members aren't already cached.
  Future<void> _warmGroupMembers(GroupRow g) async {
    for (final id in (g.memberContactIds ?? const <Uuid>[])) {
      final aid = ActorId.fromUuid(id);
      if (Actor.fromCache(aid) != null) continue;
      try {
        await Actor.getOne(aid);
      } catch (_) {
        // Contact not present locally (never synced) — dropped at resolve.
      }
    }
  }

  /// Resolve a deduped [RosterKey] into a presentable [ComposePeopleEntry], or
  /// null when nothing in the roster resolves (uncached group/contacts and no
  /// invites). A formal group wins; a single contact is a [ContactPillData];
  /// everything else (multiple contacts, or pending invites) is an ad-hoc group.
  ComposePeopleEntry? _peopleEntryFor(RosterKey r) {
    if (r.groups.isNotEmpty) {
      // Drop non-inviteable members (noreply@, mailer-daemon@, and other
      // automated senders the server flagged via `contact.inviteable`) from
      // the group's member preview so they don't surface as people.
      final g = Group.fromCache(r.groups.first);
      if (g == null) return null;
      return _groupPeopleEntry(g, r);
    }

    // Resolve roster contacts, dropping non-inviteable actors so automated
    // addresses never appear as a person to start a thread with — the at-rest
    // people list is sourced straight from authored-thread rosters, which (via
    // group bounces, CC'd daemons, transactional senders) can include them.
    // Invite emails are user-typed, so they're always kept. Filtering can
    // collapse a multi-contact roster to a single contact, so the pill type is
    // decided from the filtered set, not the raw roster.
    final actors = [
      for (final id in r.contacts) Actor.fromCache(ActorId.fromUuid(id)),
    ].whereType<Actor>().where((a) => a.inviteable).toList();
    if (actors.isEmpty && r.inviteEmails.isEmpty) return null;
    final contacts = actors.map((a) => a.id.toUuid()).toList();
    final display = contacts.length == 1 && r.inviteEmails.isEmpty
        ? ContactPillData(actors.single)
        : AdHocGroupPillData(actors, inviteEmails: r.inviteEmails);
    return ComposePeopleEntry(
      contacts: contacts,
      groups: r.groups,
      inviteEmails: r.inviteEmails,
      display: display,
    );
  }

  /// Resolve parsed [recipients] into a single roster: each address matching a
  /// known inviteable contact joins [contacts]; the rest become pending named
  /// invites encoded as `"Name <email>"` (see [InviteAddress]). Order follows
  /// [recipients].
  Future<({List<Uuid> contacts, List<String> invites})> _resolveRecipientRoster(
    List<ParsedRecipient> recipients,
  ) async {
    final contacts = <Uuid>[];
    final invites = <String>[];
    for (final r in recipients) {
      final actors = await Actor.get(
        search: r.email,
        types: const [ActorType.user, ActorType.contact],
        primary: true,
        inviteable: true,
      );
      final matched = actors
          .where((a) => (a.email ?? '').toLowerCase() == r.email)
          .toList();
      if (matched.isNotEmpty) {
        contacts.add(matched.first.id.toUuid());
      } else {
        invites.add(InviteAddress.format(email: r.email, name: r.name));
      }
    }
    return (contacts: contacts, invites: invites);
  }

  /// Step-1 sections filtered/expanded by [query]. Empty query ->
  /// [loadSections].
  Future<ComposeSections> searchSections(
    String query, {
    int perSection = 8,
    Uuid? currentFocusId,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return loadSections(perSection: perSection, currentFocusId: currentFocusId);
    }
    // Unbounded-ish base, then filter; perSection caps the final output.
    final base = await loadSections(
        perSection: _kSearchPoolLimit, currentFocusId: currentFocusId);
    final lower = trimmed.toLowerCase();

    // Email mode: when the query parses to one or more addresses (comma-,
    // semicolon-, or space-separated), synthesize a single ad-hoc People entry
    // for the combined roster so the user can start a thread with typed
    // addresses. Known correspondents join the roster as contacts; unknown
    // addresses become pending named invites. The connection is chosen in
    // step 2 ([connectionsForRoster] already carries inviteEmails).
    final recipients = EmailParser.parseRecipients(trimmed);

    bool matchesEntry(ComposePeopleEntry e) {
      final names = <String>[];
      for (final c in e.contacts) {
        final a = Actor.fromCache(ActorId.fromUuid(c));
        if (a != null) {
          names.add(a.name ?? '');
          names.add(a.email ?? '');
        }
      }
      for (final g in e.groups) {
        final grp = Group.fromCache(g);
        if (grp != null) names.add(grp.name);
      }
      names.addAll(e.inviteEmails);
      return names.any((n) => n.toLowerCase().contains(lower));
    }

    // Twist rows split their identity: [label] is the thread-type content line
    // ("Plot AI chat") while [twistHeader] holds the twist's name ("Plot"). Match
    // both so typing a twist's name surfaces it, not just its thread type.
    bool matchesTarget(ComposeTarget t) =>
        t.label.toLowerCase().contains(lower) ||
        (t.twistHeader?.toLowerCase().contains(lower) ?? false);

    // Focus ("Private notes") rows also match on focus name, ancestor path,
    // and — with more than one role — the owning role name, via
    // [Priority.matchesSearch], consistent with the other focus pickers. The
    // priority resolves against the same snapshot the focuses were built from
    // ([base.priorityById]); fall back to the shared label match when it
    // hasn't resolved.
    bool matchesFocus(ComposeTarget t) {
      final priority =
          t.priorityId == null ? null : base.priorityById[t.priorityId!];
      if (priority != null && priority.matchesSearch(trimmed)) return true;
      return matchesTarget(t);
    }

    final people = <ComposePeopleEntry>[];
    final seenRosters = <String>{};

    // Surface the typed-address roster first, above name matches.
    if (recipients.isNotEmpty) {
      final resolved = await _resolveRecipientRoster(recipients);
      final entry = _peopleEntryFor((
        contacts: resolved.contacts,
        groups: const [],
        inviteEmails: resolved.invites,
      ));
      if (entry != null &&
          seenRosters.add(
              _rosterKey(entry.contacts, entry.groups, entry.inviteEmails))) {
        people.add(entry);
      }
    }

    for (final e in base.people) {
      if (people.length >= perSection) break;
      if (matchesEntry(e) &&
          seenRosters.add(_rosterKey(e.contacts, e.groups, e.inviteEmails))) {
        people.add(e);
      }
    }

    // Synthesize matching contacts AND groups not already surfaced by a
    // recently-used roster, so search reaches the whole address book. Contacts
    // and groups are intermixed alphabetically by name.
    if (people.length < perSection) {
      final selfIds =
          Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
      final matched = <({String name, ComposePeopleEntry entry})>[];

      final contacts = await Actor.get(
        types: const [ActorType.user, ActorType.contact],
        search: trimmed,
        inviteable: true,
        primary: true,
      );
      for (final a in contacts) {
        final uuid = a.id.toUuid();
        if (selfIds.contains(uuid)) continue;
        final entry = _peopleEntryFor((
          contacts: [uuid],
          groups: const [],
          inviteEmails: const [],
        ));
        if (entry != null) matched.add((name: a.nameOrEmail, entry: entry));
      }

      // Groups: query by name directly (the People list otherwise never reaches
      // a group the user hasn't recently messaged). Build the entry straight
      // from the row so a just-created/un-cached group still resolves.
      final groupRows = await Group.getPostable(search: trimmed);
      for (final g in groupRows) {
        await _warmGroupMembers(g);
        final entry = _groupPeopleEntry(g, (
          contacts: const [],
          groups: [g.id],
          inviteEmails: const [],
        ));
        matched.add((name: g.name, entry: entry));
      }

      for (final entry in intermixPeopleByName(matched)) {
        if (people.length >= perSection) break;
        if (seenRosters
            .add(_rosterKey(entry.contacts, entry.groups, entry.inviteEmails))) {
          people.add(entry);
        }
      }
    }

    return ComposeSections(
      people: people.take(perSection).toList(),
      twists: base.twists.where(matchesTarget).take(perSection).toList(),
      channels: base.channels.where(matchesTarget).take(perSection).toList(),
      focuses: base.focuses.where(matchesFocus).take(perSection).toList(),
      drafts: const [],
      // [base] was built from one search context; carry its resolution map so
      // the filtered focuses still resolve in the view.
      priorityById: base.priorityById,
    );
  }

  /// Connections that can reach [contacts]/[groups]/[inviteEmails], MRU-first.
  /// Plot per applicable scope, plus DM-type connectors — all DM types when no
  /// group is selected, email (addresses) connectors only when a group is.
  Future<List<ComposeTarget>> connectionsForRoster({
    required List<Uuid> contacts,
    required List<Uuid> groups,
    required List<String> inviteEmails,
  }) async {
    final ctx = await _searchContextFor();
    final options = <ComposeTarget>[];
    for (final teamId in <BigInt?>{null, ...ctx.teamNames.keys}) {
      options.add(ComposeTarget.chat(
        teamId: teamId,
        hasTeams: ctx.hasTeams,
        teamName: teamId == null ? null : ctx.teamNames[teamId],
        contacts: contacts,
        groups: groups,
        inviteEmails: inviteEmails,
      ));
    }
    // DM-type connectors. With no group, offer all DM-type connectors
    // (contacts + addresses) as before. With a group selected, offer only
    // email-accepting (addresses) connectors — the group is expanded to member
    // emails at dispatch, and every member is guaranteed to have an email.
    // contacts-type DMs (e.g. Slack) are deferred until per-platform
    // reachability is modelled.
    for (final t in ctx.createTargets.where(
      (t) => t.isDmType && (groups.isEmpty || t.compose.targets == 'addresses'),
    )) {
      options.add(ComposeTarget.connector(
        t,
        connectionCount: ctx.connectionCount(t),
        contacts: contacts,
        groups: groups,
        // Carry typed-but-unresolved addresses through to compose so the
        // connector thread is addressed to them (shared) rather than private.
        inviteEmails: inviteEmails,
      ));
    }
    final ranked = _prefs.rankSignaturesByMru(
      signatures: options.map((o) => o.signature).toList(),
    );
    final bySig = {for (final o in options) o.signature: o};
    return [for (final s in ranked) if (bySig[s] != null) bySig[s]!];
  }

  /// The connection [ComposeTarget] the user last used with this **exact**
  /// roster ([contacts]/[groups]/[inviteEmails]), or null when they've never
  /// authored a thread to exactly that roster — or when the connection they
  /// used is no longer available (its connector was removed or its channel
  /// disabled, so [_composeTargetForScanThread] can't resolve a live target).
  ///
  /// Lets the step-1 picker skip the connection step (step 2) and default to
  /// the remembered connection when the user picks a roster they've messaged
  /// before. Derived from the same MRU-ranked used-combo scan as
  /// [loadSections], so the first exact-roster match in MRU order is the
  /// last-used connection. Matching is order-insensitive via [_rosterKey].
  Future<ComposeTarget?> lastUsedTargetForRoster({
    required List<Uuid> contacts,
    required List<Uuid> groups,
    required List<String> inviteEmails,
  }) async {
    final wantKey = _rosterKey(contacts, groups, inviteEmails);
    final ctx = await _searchContextFor();
    final scan = ctx.scan;
    final rankedUsed = _prefs.rankSignaturesByMru(
      signatures: buildUsedTargetSignatures(scan.threads),
    );
    for (final sig in rankedUsed) {
      final st = scan.bySignature[sig];
      if (st == null) continue;
      final target = _composeTargetForScanThread(
        st,
        templateBySignature: ctx.templateBySignature,
        connectionCount: ctx.connectionCount,
        hasTeams: ctx.hasTeams,
        teamNames: ctx.teamNames,
      );
      // A null target means the combo's connection is gone (template
      // unresolvable) — skip it; a later, still-available combo for the same
      // roster may still win, otherwise we fall through to null (→ step 2).
      if (target == null) continue;
      if (_rosterKey(target.contacts, target.groups, target.inviteEmails) ==
          wantKey) {
        return target;
      }
    }
    return null;
  }

  /// Resolve a [ComposeTarget] for a used-combo scan thread, or null when its
  /// connector template is no longer available (connection removed, channel
  /// disabled).
  ComposeTarget? _composeTargetForScanThread(
    ComposeScanThread st, {
    required Map<String, CreateTarget> templateBySignature,
    required int Function(CreateTarget) connectionCount,
    required bool hasTeams,
    required Map<BigInt, String> teamNames,
  }) {
    final link = st.primaryLink;
    if (link == null) {
      // Plot note/chat: no roster → note, roster → chat.
      final hasRoster = st.contacts.isNotEmpty || st.groups.isNotEmpty;
      final teamName = st.teamId == null ? null : teamNames[st.teamId];
      if (!hasRoster) {
        // No-roster Plot threads are surfaced as focus-note rows from
        // focusNoteOrder (templates section), not here.
        return null;
      }
      // Keep the roster: a rostered chat is a "message these people" row and
      // must show its contacts (the row's whole point). The roster is folded
      // into the signature, so distinct rosters rank as distinct rows and
      // repeat rosters dedupe — there's no bare "Chat" template to collapse
      // onto anymore. Names resolve from the warmed Actor cache.
      final chatDetail = _contactDetailFor(st.contacts);
      return ComposeTarget.chat(
        teamId: st.teamId,
        hasTeams: hasTeams,
        teamName: teamName,
        contactDetail: chatDetail,
        contacts: st.contacts,
        groups: st.groups,
      );
    }

    // Connector combo: match the bare connection key to a live template.
    final baseKey = connectionTargetKey(
      twistInstanceId: link.instanceId.toString(),
      channelId: link.channelId,
      linkType: link.linkType,
      dmTargets: link.dmTargets,
    );
    final template = templateBySignature[baseKey];
    if (template == null) return null;
    // DM/address combos carry the roster; channel combos do not (per the
    // signature scheme), so only forward contacts for DM-type targets. Keep
    // the roster for every DM combo: a Gmail/Slack-DM row is a "message this
    // person" row and must show its contact(s). The roster is in the signature
    // (distinct people → distinct rows, repeats dedupe), and bare DM-type
    // templates no longer exist to collapse onto, so there's nothing to gain
    // from dropping it. Names resolve from the warmed Actor cache.
    final isDm = template.isDmType;
    final contactDetail = _contactDetailFor(isDm ? st.contacts : const []);
    return ComposeTarget.connector(
      template,
      connectionCount: connectionCount(template),
      channelDetail: template.channel?.title,
      contactDetail: contactDetail,
      contacts: isDm ? st.contacts : const [],
    );
  }

  /// A short " · Name" detail for a roster's first contact, or null. Uses the
  /// synchronous Actor cache; falls back to no detail when uncached.
  String? _contactDetailFor(List<Uuid> contacts) {
    if (contacts.isEmpty) return null;
    final actor = Actor.fromCache(ActorId.fromUuid(contacts.first));
    final name = actor?.nameOrEmail;
    if (name == null || name.isEmpty) return null;
    return contacts.length > 1 ? '$name +${contacts.length - 1}' : name;
  }

  // --- Search synthesis ----------------------------------------------------

  /// Name-match synthesis for [query]. For every matching contact, returns the
  /// connections previously **used** to reach them first (from the authored-
  /// thread scan), then **every** other way to reach them — a Plot chat per
  /// scope plus each address/contacts-capable connection — so the user can
  /// message someone for the first time via a connection they haven't used with
  /// that person yet. Deduped by signature, so a used connection appears once
  /// (in its higher-ranked position).
  Future<List<ComposeTarget>> _searchByName(String query) async {
    // Only the *set* of name-matching correspondent ids is needed — the
    // authored-thread scan below supplies recency and roster. A lean [Actor.get]
    // LIKE query yields the same id set as the full share ranking
    // ([Actor.getSortedForSharing] only orders candidates, it never filters
    // them) at a fraction of the cost, so it stays cheap on every keystroke.
    final matches = await Actor.get(
      types: [ActorType.user, ActorType.contact],
      search: query,
      inviteable: true,
      primary: true,
    );
    if (matches.isEmpty) return const [];
    final matchIds = matches.map((a) => a.id.toUuid()).toSet();

    final ctx = await _searchContextFor();

    // Scan authored threads for combos whose roster touches a matching
    // correspondent, on contact/DM/address-capable targets (Plot chat or a
    // connector DM/address target — channel targets aren't roster-keyed).
    final out = <ComposeTarget>[];
    for (final st in ctx.scan.threads) {
      final touches = st.contacts.any(matchIds.contains);
      if (!touches) continue;
      final link = st.primaryLink;
      if (link == null) {
        // Plot chat with this correspondent.
        if (st.contacts.isEmpty && st.groups.isEmpty) continue;
        out.add(ComposeTarget.chat(
          teamId: st.teamId,
          hasTeams: ctx.hasTeams,
          teamName: st.teamId == null ? null : ctx.teamNames[st.teamId],
          contactDetail: _contactDetailFor(st.contacts),
          contacts: st.contacts,
          groups: st.groups,
        ));
        continue;
      }
      final baseKey = connectionTargetKey(
        twistInstanceId: link.instanceId.toString(),
        channelId: link.channelId,
        linkType: link.linkType,
        dmTargets: link.dmTargets,
      );
      final template = ctx.templateBySignature[baseKey];
      if (template == null || !template.isDmType) continue;
      out.add(ComposeTarget.connector(
        template,
        connectionCount: ctx.connectionCount(template),
        contactDetail: _contactDetailFor(st.contacts),
        contacts: st.contacts,
      ));
    }

    // Beyond the connections already used with the matched contacts (added
    // above, so they rank first and win the dedup), offer EVERY other way to
    // reach them — a Plot chat per scope and every address/contacts-capable
    // connection — so you can message someone for the first time via a new
    // connection. Cap the matched contacts so a common name doesn't explode the
    // list; the address-capable connection set is already small.
    final teamScopes = <BigInt?>[null, ...ctx.teams.map((t) => t.teamId)];
    for (final actor in matches.take(8)) {
      final cid = actor.id.toUuid();
      final detail = actor.nameOrEmail;
      for (final teamId in teamScopes) {
        out.add(ComposeTarget.chat(
          teamId: teamId,
          hasTeams: ctx.hasTeams,
          teamName: teamId == null ? null : ctx.teamNames[teamId],
          contactDetail: detail,
          contacts: [cid],
        ));
      }
      for (final template in ctx.createTargets.where((t) => t.isDmType)) {
        out.add(ComposeTarget.connector(
          template,
          connectionCount: ctx.connectionCount(template),
          contactDetail: detail,
          contacts: [cid],
        ));
      }
    }
    return _dedupeBySignature(out);
  }

  /// Email-mode synthesis for one or more parsed recipients. Resolves each
  /// address to a known contact (added to the roster) or a pending named
  /// invite, then emits Plot Chat options (Personal + each team, pinned)
  /// carrying ALL recipients, followed by address-capable connections carrying
  /// the same roster. Named invites are encoded as `"Name <email>"`.
  Future<List<ComposeTargetView>> _searchByRecipients(
    List<ParsedRecipient> recipients,
  ) async {
    final ctx = await _searchContextFor();

    final resolved = await _resolveRecipientRoster(recipients);
    final contactIds = resolved.contacts;
    final invites = resolved.invites;

    // 1. Plot Chat options (Personal + each active team), pinned to the top.
    final teamScopes = <BigInt?>[null, ...ctx.teams.map((t) => t.teamId)];
    final chats = <ComposeTarget>[
      for (final teamId in teamScopes)
        ComposeTarget.chat(
          teamId: teamId,
          hasTeams: ctx.hasTeams,
          teamName: teamId == null ? null : ctx.teamNames[teamId],
          contactDetail: null, // presentation comes from the view's recipients
          contacts: contactIds,
          groups: const [],
          inviteEmails: invites,
        ),
    ];

    // 2. Address-capable connections carrying the same roster.
    final addressCapable = ctx.createTargets
        .where((t) => t.isDmType)
        .map((t) => ComposeTarget.connector(
              t,
              connectionCount: ctx.connectionCount(t),
              contacts: contactIds,
              // Carry the pending invites so picking a connection for a typed
              // address sends to it instead of composing a recipientless thread.
              inviteEmails: invites,
            ))
        .toList();
    final ranked = _prefs.rankSignaturesByMru(
      signatures: addressCapable.map((t) => t.signature).toList(),
    );
    final bySig = {for (final t in addressCapable) t.signature: t};
    final rankedConnectors = [for (final sig in ranked) bySig[sig]!];

    return _toViews(
        _dedupeBySignature([...chats, ...rankedConnectors]), ctx);
  }

  // --- Authored-thread scan ------------------------------------------------

  /// Loads recent authored threads (full rows) plus their links, and maps
  /// each to a [ComposeScanThread]. Most-recent first.
  Future<_ComposeScan> _scanAuthoredThreads() async {
    final selfIds =
        Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    if (selfIds.isEmpty) return const _ComposeScan([]);

    final rows = await _authoredThreadRows(selfIds, _authoredScanWindow);
    if (rows.isEmpty) return const _ComposeScan([]);

    // Batch-load links for all scanned threads in one query, then group.
    final threadIds = rows.map((r) => r.id).toList();
    final linksByThread = await _linksForThreads(threadIds);

    final scanThreads = <ComposeScanThread>[];
    for (final row in rows) {
      final links = linksByThread[row.id] ?? const <Link>[];
      // The roster a combo represents is the *other* participants — drop the
      // user's own contacts so "Gmail with Greg" doesn't carry the user's own
      // address (which would also wrongly prefill them as a recipient in
      // step-2 compose). thread.contacts always includes the author's primary
      // contact for human-authored threads.
      final contacts = (row.contacts ?? const <Uuid>[])
          .where((c) => !selfIds.contains(c))
          .toList();
      scanThreads.add(ComposeScanThread(
        teamId: row.teamId,
        contacts: contacts,
        groups: row.groups ?? const [],
        primaryLink: _primaryScanLink(links),
        priorityId: row.priorityId,
        recencyMs: (row.lastNoteCreatedAt ?? row.bumpedAt ?? row.createdAt)
            .millisecondsSinceEpoch,
      ));
    }
    return _ComposeScan(scanThreads);
  }

  /// The primary canonical link mapped to a [ComposeScanLink], or null when the
  /// thread is a native (link-less) Plot thread or the link can't be resolved.
  /// Uses [Thread.primaryLink] so this agrees with [Thread.resolveSharingModel].
  static ComposeScanLink? _primaryScanLink(List<Link> links) {
    final link = Thread.primaryLink(links);
    if (link == null) return null;
    final instanceId = link.createdBy;
    final linkType = link.type;
    if (instanceId == null || linkType == null) return null;
    final dmTargets = link.getTypeConfig()?.compose?.targets;
    return ComposeScanLink(
      instanceId: instanceId,
      channelId: link.channelId,
      linkType: linkType,
      dmTargets: dmTargets,
    );
  }

  /// Most-recent [limit] non-archived, non-draft threads the user has authored
  /// at least one note in, newest first. Returns raw rows — we only read
  /// `teamId`/`contacts`/`groups`/`id`, so this avoids the priority join that
  /// `Thread._fromStore` requires. Mirrors `authoredThreadsForSharing` in
  /// `actor.dart`.
  Future<List<ThreadRow>> _authoredThreadRows(
    Set<Uuid> selfIds,
    int limit,
  ) async {
    final a = Store.get.threads;
    final n = Store.get.alias(Store.get.notes, 'compose_authored_note');
    final selfBytes = selfIds.map((id) => id.toBytes()).toList();
    final query = Store.get.select(a)
      ..where(
        (row) =>
            row.archivedAt.isNull() &
            row.draft.equals(false) &
            existsQuery(
              Store.get.selectOnly(n)
                ..addColumns([n.id])
                ..where(
                  n.threadId.equalsExp(a.id) & n.authorId.isIn(selfBytes),
                ),
            ),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.lastNoteCreatedAt),
        (row) => OrderingTerm.desc(row.bumpedAt),
        (row) => OrderingTerm.desc(row.createdAt),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<Map<ThreadId, List<Link>>> _linksForThreads(
    List<ThreadId> threadIds,
  ) async {
    if (threadIds.isEmpty) return const {};
    final idBytes = threadIds.map((id) => id.toBytes()).toList();
    final rows = await (Store.get.select(Store.get.links)
          ..where((l) => l.threadId.isIn(idBytes)))
        .get();
    final out = <ThreadId, List<Link>>{};
    for (final row in rows) {
      final link = Link(row);
      final tid = link.threadId;
      if (tid == null) continue;
      out.putIfAbsent(tid, () => []).add(link);
    }
    return out;
  }

  // --- Pure helpers (unit-testable, no DB) ---------------------------------

  /// The canonical [ComposeTarget] signature for a scanned thread. Pure.
  ///
  /// - No primary link → Plot thread: empty roster → note, else chat (with
  ///   team + roster).
  /// - Primary link → connector signature. Channel-type targets carry **no**
  ///   roster suffix; DM/address-type targets carry the thread's contacts as
  ///   `:c=` (per the signature scheme).
  static String composeSignatureForScanThread(ComposeScanThread st) {
    final link = st.primaryLink;
    if (link == null) {
      final hasRoster = st.contacts.isNotEmpty || st.groups.isNotEmpty;
      return hasRoster
          ? composeChatSignature(
              st.teamId,
              contacts: st.contacts,
              groups: st.groups,
            )
          : composeNoteSignature(st.teamId);
    }
    final isDm =
        link.dmTargets == 'contacts' || link.dmTargets == 'addresses';
    return composeConnectorSignature(
      twistInstanceId: link.instanceId.toString(),
      channelId: link.channelId,
      linkType: link.linkType,
      dmTargets: link.dmTargets,
      contacts: isDm ? st.contacts : const [],
    );
  }

  /// Ordered, deduped signatures for a list of scanned threads
  /// (most-recent-first). Pure.
  static List<String> buildUsedTargetSignatures(
    List<ComposeScanThread> threads,
  ) {
    final seen = <String>{};
    final out = <String>[];
    for (final st in threads) {
      final sig = composeSignatureForScanThread(st);
      if (seen.add(sig)) out.add(sig);
    }
    return out;
  }

  /// The id with the highest count in [counts] (first key wins ties). Used to
  /// pick the most-common focus per connection for the header tint.
  static Uuid _topByCount(Map<Uuid, int> counts) {
    var best = counts.keys.first;
    var bestN = -1;
    counts.forEach((k, n) {
      if (n > bestN) {
        best = k;
        bestN = n;
      }
    });
    return best;
  }

  /// The most-common Plot scope (team id, null = Personal) in [counts]. Used to
  /// pick the scope a focus-note row carries.
  static BigInt? _topScope(Map<BigInt?, int> counts) {
    BigInt? best;
    var bestN = -1;
    counts.forEach((k, n) {
      if (n > bestN) {
        best = k;
        bestN = n;
      }
    });
    return best;
  }

  static List<ComposeTarget> _dedupeBySignature(List<ComposeTarget> targets) {
    final seen = <String>{};
    final out = <ComposeTarget>[];
    for (final t in targets) {
      if (seen.add(t.signature)) out.add(t);
    }
    return out;
  }

  /// Dedup for the user-facing base list: collapse both exact-signature
  /// duplicates **and** entries that would render identically (same [label]),
  /// keeping the first (highest-ranked) of each. A label collision means two
  /// rows are visually indistinguishable to the user even when their roster
  /// signatures differ — e.g. two recent "Gmail (account)" DM combos whose
  /// correspondents didn't resolve to a visible detail — so showing both is
  /// just noise. Distinct labels ("Gmail · Greg Smith", "Chat (Acme)") are
  /// preserved.
  static List<ComposeTarget> _dedupeForDisplay(List<ComposeTarget> targets) {
    final seenSig = <String>{};
    final seenLabel = <String>{};
    final out = <ComposeTarget>[];
    for (final t in targets) {
      if (!seenSig.add(t.signature)) continue;
      if (!seenLabel.add(t.label)) continue;
      out.add(t);
    }
    return out;
  }
}

/// Query-independent inputs shared across base-list materialization and
/// per-keystroke search synthesis (teams, connector create-targets, and the
/// recent authored-thread roster scan). Cached by [ComposeTargetsBloc] and
/// rebuilt only when [ComposeTargetsBloc.refresh] / a cache prepend invalidates
/// it, so typing a name doesn't re-run these queries on every keystroke.
class _ComposeSearchContext {
  const _ComposeSearchContext({
    required this.teams,
    required this.hasTeams,
    required this.teamNames,
    required this.createTargets,
    required this.connectionCountByTwistId,
    required this.templateBySignature,
    required this.scan,
    required this.colorByConnection,
    required this.priorityById,
    required this.nameToEmailsByConnection,
    required this.focusNoteOrder,
  });

  final List<TeamUserRow> teams;
  final bool hasTeams;
  final Map<BigInt, String> teamNames;
  final List<CreateTarget> createTargets;

  /// Connection count per connector package (same twistId = same connector),
  /// so the account-label parenthetical shows only when >1 connection.
  final Map<BigInt, int> connectionCountByTwistId;

  /// Connector templates indexed by their bare connection signature
  /// ([CreateTarget.key]).
  final Map<String, CreateTarget> templateBySignature;

  /// Recent authored-thread roster scan (with a by-signature index).
  final _ComposeScan scan;

  /// Most-common focus colour per connectionColorKey.
  final Map<String, ThemeColor> colorByConnection;

  /// Focuses resolved for focus-note rows + colour lookups, by id.
  final Map<Uuid, Priority> priorityById;

  /// Per connectionColorKey: lowercased contact name -> addresses (primary-first).
  final Map<String, Map<String, List<String>>> nameToEmailsByConnection;

  /// Focuses to surface as focus-note rows, MRU-first, each with its most-common
  /// Plot scope. (priorityId, teamId-of-most-common-scope)
  final List<({Uuid priorityId, BigInt? teamId})> focusNoteOrder;

  int connectionCount(CreateTarget t) =>
      connectionCountByTwistId[t.twist.twistId] ?? 1;
}

/// Result of the authored-thread scan, with a signature index for combo
/// resolution.
class _ComposeScan {
  const _ComposeScan(this.threads);

  final List<ComposeScanThread> threads;

  Map<String, ComposeScanThread> get bySignature {
    final map = <String, ComposeScanThread>{};
    for (final st in threads) {
      // First occurrence wins (most-recent-first input).
      map.putIfAbsent(
        ComposeTargetsBloc.composeSignatureForScanThread(st),
        () => st,
      );
    }
    return map;
  }
}

/// Minimal thread shape consumed by the pure signature derivation: its team,
/// roster, and primary link. Kept DB-free so the ranking is unit-testable —
/// mirrors `ShareScanThread` in `actor.dart`.
class ComposeScanThread extends Equatable {
  const ComposeScanThread({
    this.teamId,
    this.contacts = const [],
    this.groups = const [],
    this.primaryLink,
    required this.priorityId,
    this.recencyMs = 0,
  });

  final BigInt? teamId;
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final ComposeScanLink? primaryLink;
  final Uuid priorityId; // the thread's filed focus (non-null on ThreadRow)

  /// Recency of this thread (epoch ms): `lastNoteCreatedAt ?? bumpedAt ??
  /// createdAt`. Drives the People-list true-MRU ordering. Defaults to 0 for
  /// pure-helper/test construction where recency is irrelevant.
  final int recencyMs;

  @override
  List<Object?> get props =>
      [teamId, contacts, groups, primaryLink, priorityId, recencyMs];
}

/// The primary-link facet of a [ComposeScanThread] needed to derive a
/// connector signature.
class ComposeScanLink extends Equatable {
  const ComposeScanLink({
    required this.instanceId,
    required this.channelId,
    required this.linkType,
    required this.dmTargets,
  });

  /// The connection (`twist_instance`) that created the link — `link.createdBy`.
  final Uuid instanceId;
  final String? channelId;
  final String linkType;

  /// `compose.targets` of the link type: `channels` (default), `contacts`, or
  /// `addresses`. Null is treated as channel-type.
  final String? dmTargets;

  @override
  List<Object?> get props => [instanceId, channelId, linkType, dmTargets];
}
