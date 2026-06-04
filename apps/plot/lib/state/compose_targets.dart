import 'package:drift/drift.dart' hide Column;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart' show ThemeColor;
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/compose_target_view.dart';
import 'package:plot/widget/compose/email_parser.dart';
import 'package:plot/widget/connection_targets.dart';

part 'compose_targets_state.dart';

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
      : super(const ComposeTargetsState(targets: []));

  final LocalPreferencesBloc _prefs;

  /// How many recent authored threads to scan for used combinations. The
  /// base list stays conservative (recently-used combos + one fresh template
  /// per connection); the full channel/contact space is reachable via
  /// [search]. Mirrors the share-scan window in `actor.dart`.
  static const int _authoredScanWindow = 80;

  /// Rebuild the cached base list from the stores + MRU recency. Call on the
  /// inputs that change it: connections/channels syncing, team membership
  /// changing, and after recording a created thread (see [recordTarget],
  /// which also fast-paths a prepend so the next open reflects it instantly).
  Future<void> refresh() async {
    // The cached search context is derived from the same stores this rebuilds,
    // so drop it first and let [_materializeBaseList] repopulate it from fresh
    // data; subsequent per-keystroke searches then reuse that fresh context.
    _invalidateSearchContext();
    final targets = await _materializeBaseList();
    // _materializeBaseList already awaited _searchContextFor(), so this returns
    // the freshly-cached context (no extra queries).
    final ctx = await _searchContextFor();
    emit(state.copyWith(targets: _toViews(targets, ctx)));
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
    final teams = await TeamUser.getActive();
    final createTargets = await loadCreateTargets();
    final scan = await _scanAuthoredThreads();

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
    // Twist targets (chat with a twist). Only twists that opt in via a
    // non-empty `threadType` and aren't source/connector instances are chat
    // targets — connectors are also twist_instances, so without this filter a
    // connection (e.g. Gmail) would wrongly appear as a "chat with a twist"
    // row. Matches the `chatTwists` filter in connection_chip.dart.
    final twists = await TwistInstance.get();
    final chatTwists = twists
        .where((t) => !t.isSource && (t.threadType?.isNotEmpty ?? false))
        .toList();
    for (final twist in chatTwists) {
      templates.add(ComposeTarget.twist(
        twist,
        allInstances: twists,
        teamName: twist.teamId == null ? null : ctx.teamNames[twist.teamId],
      ));
    }
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

    final contactIds = <Uuid>[];
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
        contactIds.add(matched.first.id.toUuid());
      } else {
        invites.add(InviteAddress.format(email: r.email, name: r.name));
      }
    }

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
      ));
    }
    return _ComposeScan(scanThreads);
  }

  /// The earliest-created link mapped to a [ComposeScanLink], or null when the
  /// thread is a native (link-less) Plot thread or the link can't be resolved.
  static ComposeScanLink? _primaryScanLink(List<Link> links) {
    if (links.isEmpty) return null;
    final primary = [...links]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final link = primary.first;
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
  });

  final BigInt? teamId;
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final ComposeScanLink? primaryLink;
  final Uuid priorityId; // the thread's filed focus (non-null on ThreadRow)

  @override
  List<Object?> get props => [teamId, contacts, groups, primaryLink, priorityId];
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
