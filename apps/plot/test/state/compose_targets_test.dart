import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/connection_targets.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Pure signature + model + label tests (no DB).
  // ---------------------------------------------------------------------------
  group('ComposeTarget signature scheme', () {
    test('no-roster connector signature equals CreateTarget.key', () {
      final instance = Uuid.generate();
      // Channel-type signature.
      final channelSig = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: 'C123',
        linkType: 'thread',
        dmTargets: 'channels',
      );
      expect(
        channelSig,
        connectionTargetKey(
          twistInstanceId: instance.toString(),
          channelId: 'C123',
          linkType: 'thread',
          dmTargets: 'channels',
        ),
      );
      expect(channelSig, '$instance|C123|thread');

      // DM-type (no roster) signature.
      final dmSig = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: null,
        linkType: 'dm',
        dmTargets: 'contacts',
      );
      expect(
        dmSig,
        connectionTargetKey(
          twistInstanceId: instance.toString(),
          channelId: null,
          linkType: 'dm',
          dmTargets: 'contacts',
        ),
      );
      expect(dmSig, '$instance||dm|contacts');
    });

    test('roster appends :c= (sorted) and ranks distinctly from bare key', () {
      final instance = Uuid.generate();
      // Build two contact ids and ensure the suffix is sorted regardless of
      // input order.
      final a = Uuid.fromString('00000000-0000-0000-0000-000000000001');
      final b = Uuid.fromString('00000000-0000-0000-0000-000000000002');

      final bare = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: null,
        linkType: 'dm',
        dmTargets: 'contacts',
      );
      final withRoster = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: null,
        linkType: 'dm',
        dmTargets: 'contacts',
        contacts: [b, a],
      );
      expect(withRoster, '$bare:c=$a,$b');
      expect(withRoster, isNot(bare));
    });

    test('chat signature carries team + sorted roster; note is team-only', () {
      final team = BigInt.from(7);
      final g1 = Uuid.fromString('00000000-0000-0000-0000-0000000000a2');
      final g2 = Uuid.fromString('00000000-0000-0000-0000-0000000000a1');
      final c1 = Uuid.fromString('00000000-0000-0000-0000-0000000000b1');

      expect(composeNoteSignature(null), 'note:personal');
      expect(composeNoteSignature(team), 'note:7');

      expect(composeChatSignature(null), 'chat:personal');
      expect(
        composeChatSignature(team, contacts: [c1], groups: [g1, g2]),
        'chat:7:c=$c1:g=$g2,$g1',
      );
    });

    test('twist signature is twist:<instanceId>', () {
      final instance = Uuid.generate();
      expect(composeTwistSignature(instance), 'twist:$instance');
    });
  });

  group('composeSignatureForScanThread (recent-thread derivation)', () {
    test('link-less thread → note when no roster, chat when roster', () {
      final team = BigInt.from(3);
      final c = Uuid.generate();

      final note = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(teamId: team),
      );
      expect(note, composeNoteSignature(team));

      final chat = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(teamId: team, contacts: [c]),
      );
      expect(chat, composeChatSignature(team, contacts: [c]));
    });

    test('channel-type link → no roster suffix even with thread contacts', () {
      final instance = Uuid.generate();
      final c = Uuid.generate();
      final sig = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(
          contacts: [c],
          primaryLink: ComposeScanLink(
            instanceId: instance,
            channelId: 'C1',
            linkType: 'thread',
            dmTargets: 'channels',
          ),
        ),
      );
      // Must equal the bare channel key — channel combos aren't roster-keyed.
      expect(sig, '$instance|C1|thread');
    });

    test('dm-type link → roster carried as :c=', () {
      final instance = Uuid.generate();
      final c = Uuid.fromString('00000000-0000-0000-0000-0000000000c1');
      final sig = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(
          contacts: [c],
          primaryLink: ComposeScanLink(
            instanceId: instance,
            channelId: null,
            linkType: 'dm',
            dmTargets: 'contacts',
          ),
        ),
      );
      expect(sig, '$instance||dm|contacts:c=$c');
    });

    test('round-trips: thread-derived signature == CreateTarget-derived', () {
      final instance = Uuid.generate();
      // The connector signature derived from a recent channel thread matches
      // the one a fresh CreateTarget template would produce (no roster).
      final fromThread = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(
          primaryLink: ComposeScanLink(
            instanceId: instance,
            channelId: 'C9',
            linkType: 'thread',
            dmTargets: 'channels',
          ),
        ),
      );
      final fromTarget = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: 'C9',
        linkType: 'thread',
        dmTargets: 'channels',
      );
      expect(fromThread, fromTarget);
    });
  });

  group('buildUsedTargetSignatures', () {
    test('dedupes by signature, most-recent-first', () {
      final team = BigInt.from(1);
      final c = Uuid.generate();
      final threads = [
        ComposeScanThread(teamId: team, contacts: [c]), // chat:1:c=...
        ComposeScanThread(teamId: team), // note:1
        ComposeScanThread(teamId: team, contacts: [c]), // dup of first
      ];
      final sigs = ComposeTargetsBloc.buildUsedTargetSignatures(threads);
      expect(sigs, [
        composeChatSignature(team, contacts: [c]),
        composeNoteSignature(team),
      ]);
    });
  });

  group('ComposeTarget.label parentheticals', () {
    test('Note/Chat: team parenthetical only when the user has teams', () {
      final team = BigInt.from(4);
      // Zero teams → bare labels.
      expect(
        ComposeTarget.note(hasTeams: false).label,
        'Note',
      );
      expect(
        ComposeTarget.chat(hasTeams: false).label,
        'Chat',
      );
      // ≥1 team → parenthetical (Personal / team name).
      expect(
        ComposeTarget.note(hasTeams: true).label,
        'Note (Personal)',
      );
      expect(
        ComposeTarget.chat(teamId: team, hasTeams: true, teamName: 'Acme')
            .label,
        'Chat (Acme)',
      );
    });

    test('connector: account parenthetical only when >1 connection', () {
      final target = _fakeCreateTarget(
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      // Single connection → bare connector name.
      expect(
        ComposeTarget.connector(target, connectionCount: 1).label,
        'Gmail',
      );
      // >1 connection → account label appended.
      expect(
        ComposeTarget.connector(target, connectionCount: 2).label,
        'Gmail (kris@plot.day)',
      );
      // Channel/contact detail appends after the connector label.
      expect(
        ComposeTarget.connector(
          target,
          connectionCount: 2,
          contactDetail: 'Greg Smith',
        ).label,
        'Gmail (kris@plot.day) · Greg Smith',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cache prepend (bloc state, no DB).
  // ---------------------------------------------------------------------------
  group('ComposeTargetsBloc cache prepend', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('prependToCache moves an existing signature to the front', () async {
      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);

      final note = ComposeTarget.note(hasTeams: false);
      final chat = ComposeTarget.chat(hasTeams: false);
      bloc.prependToCache(note);
      bloc.prependToCache(chat);
      expect(bloc.state.targets.map((t) => t.signature),
          [chat.signature, note.signature]);

      // Re-recording note moves it to the front without duplicating.
      bloc.prependToCache(note);
      expect(bloc.state.targets.map((t) => t.signature),
          [note.signature, chat.signature]);
      expect(bloc.state.targets.length, 2);
    });

    test('recordTarget records the signature in the connection MRU', () async {
      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);

      final chat = ComposeTarget.chat(hasTeams: false);
      await bloc.recordTarget(chat);

      expect(prefs.lastUsedMsForSignature(chat.signature), isNotNull);
      expect(bloc.state.targets.first.signature, chat.signature);
    });
  });

  // ---------------------------------------------------------------------------
  // Integration: base-list materialization + search against in-memory Drift.
  // ---------------------------------------------------------------------------
  group('ComposeTargetsBloc materialization (in-memory store)', () {
    late Store store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
      store = Store.forTesting(NativeDatabase.memory());
      Injector.appInstance
          .registerSingleton<Store>(() => store, override: true);
      Actor.clearCache();
      TwistInstance.clearCache();
      Channel.populateCache(const []);
    });

    tearDown(() async {
      Actor.clearCache();
      TwistInstance.clearCache();
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    });

    test(
        'base list contains Note/Chat (Personal + each team) and per-connection '
        'templates; used combos rank ahead by recency', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      // Resolve self into the Actor cache for getCurrentUserActorIds(), and
      // load all actors so Greg is in the synchronous cache. A DM/address
      // combo only keeps its roster (ranking distinctly) when its correspondent
      // resolves to a visible detail — otherwise it collapses onto the bare
      // connector template (see _composeTargetForScanThread).
      await Actor.get(self: true);
      await Actor.get();

      // One team membership → Note/Chat for Personal + the team.
      await _insertTeamUser(store, teamId: BigInt.from(42), name: 'Acme');

      // A Gmail-style address connector with one enabled channel that has a
      // compose block (so loadCreateTargets emits a template for it).
      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );

      // A recent authored DM thread to Greg via Gmail → a used combo.
      final dmThread = Uuid.generate();
      await _insertThread(store, dmThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, dmThread, author: self);
      await _insertLink(store, dmThread,
          createdBy: gmail, type: 'email', channelId: null);

      // A recent authored native chat → a used Plot chat combo.
      final chatThread = Uuid.generate();
      await _insertThread(store, chatThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 4, 1));
      await _insertNote(store, chatThread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      final labels = bloc.state.targets.map((t) => t.label).toList();
      final sigs = bloc.state.targets.map((t) => t.signature).toList();

      // Note/Chat for Personal + the team are present (with team parenthetical
      // because the user has ≥1 team).
      expect(labels, containsAll(<String>[
        'Note (Personal)',
        'Chat (Personal)',
        'Note (Acme)',
        'Chat (Acme)',
      ]));

      // The Gmail connector template is present.
      expect(sigs, contains(
        composeConnectorSignature(
          twistInstanceId: gmail.toString(),
          channelId: null,
          linkType: 'email',
          dmTargets: 'addresses',
        ),
      ));

      // The used combos (Gmail-with-Greg DM, then native chat-with-Greg) rank
      // ahead of the bare templates, most-recent first.
      final gmailGregSig = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [greg],
      );
      // The roster drops the user's own contact, so the chat combo is
      // "with Greg" only.
      final chatGregSig = composeChatSignature(null, contacts: [greg]);
      expect(sigs.first, gmailGregSig);
      expect(sigs.indexOf(chatGregSig), 1);

      // Because Greg resolves to a name in the Actor cache, both rostered
      // combos render *distinctly* (the roster is surfaced in the label) so
      // they don't read as duplicates of the bare templates — and the bare
      // "Chat (Personal)" template still coexists as its own entry.
      final byLabel = {for (final t in bloc.state.targets) t.signature: t.label};
      expect(byLabel[gmailGregSig], 'Gmail · Greg Smith');
      expect(byLabel[chatGregSig], 'Chat (Personal) · Greg Smith');
      expect(labels, contains('Chat (Personal)')); // bare template kept
      // No two rows render identically.
      expect(labels.toSet().length, labels.length);
    });

    test('search("") and search("   ") return the cached base list '
        '(Note + Chat Personal)', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      // With no teams the base list always offers a Personal Note and Chat,
      // independent of connections/teams loading. This is the contract the
      // step-1 TargetPickerList relies on to render on a fresh open with an
      // empty query (the picker re-seeds from this list when refresh() emits).
      final baseSigs = bloc.state.targets.map((t) => t.signature).toList();
      expect(baseSigs, contains(composeNoteSignature(null)));
      expect(baseSigs, contains(composeChatSignature(null)));

      // An empty (and a blank/whitespace-only) query falls back to that cached
      // base list rather than returning [].
      final emptySigs =
          (await bloc.search('')).map((t) => t.signature).toList();
      final blankSigs =
          (await bloc.search('   ')).map((t) => t.signature).toList();
      expect(emptySigs, baseSigs);
      expect(blankSigs, baseSigs);
      expect(emptySigs, contains(composeNoteSignature(null)));
      expect(emptySigs, contains(composeChatSignature(null)));
    });

    test('search("greg") returns combos for an authored correspondent and '
        'excludes a send-only contact', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate(); // authored correspondent
      final noreply = Uuid.generate(); // send-only (received, never authored)
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, noreply, name: 'Greg Noreply');
      await Actor.get(self: true);

      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );

      // Authored DM thread to Greg.
      final gregThread = Uuid.generate();
      await _insertThread(store, gregThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, gregThread, author: self);
      await _insertLink(store, gregThread,
          createdBy: gmail, type: 'email', channelId: null);

      // Inbound-only thread from "Greg Noreply" — the user never authored a
      // note here, so the authored/replied banding must exclude it.
      final noreplyThread = Uuid.generate();
      await _insertThread(store, noreplyThread,
          priorityId: priorityId,
          contacts: [self, noreply],
          createdAt: DateTime(2026, 5, 2));
      // No self-authored note on this thread.

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      final results = await bloc.search('greg');
      final sigs = results.map((t) => t.signature).toList();

      final gregCombo = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [greg],
      );
      expect(sigs, contains(gregCombo));

      // No combo references the send-only "Greg Noreply" contact.
      final noreplyCombo = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [noreply],
      );
      expect(sigs, isNot(contains(noreplyCombo)));
    });

    test(
        'per-keystroke search reuses a cached context; refresh() invalidates it',
        () async {
      // Guards the search-performance optimization: a name search must NOT
      // re-run the team / connector / authored-thread queries on every
      // keystroke. Instead it reads a context cached at refresh() time, so a
      // store mutation isn't reflected until the cache is invalidated. Before
      // the optimization every search re-scanned the store, so the new combo
      // appeared immediately and the "stale" expectation below would fail.
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      // Build the initial context — no connectors, no authored history yet.
      await bloc.refresh();

      // Now add an authored Gmail DM to Greg *after* the context was cached.
      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final thread = Uuid.generate();
      await _insertThread(store, thread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, thread, author: self);
      await _insertLink(store, thread,
          createdBy: gmail, type: 'email', channelId: null);

      final gregCombo = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [greg],
      );

      // Cached context (from the first refresh) has neither the connector
      // template nor the authored thread, so the combo isn't synthesized yet.
      final stale = await bloc.search('greg');
      expect(stale.map((t) => t.signature), isNot(contains(gregCombo)),
          reason: 'search must not re-scan the store on every keystroke');

      // refresh() invalidates the cache; the next search rebuilds from fresh
      // data and now surfaces the combo.
      await bloc.refresh();
      final fresh = await bloc.search('greg');
      expect(fresh.map((t) => t.signature), contains(gregCombo),
          reason: 'refresh() must invalidate the cached search context');
    });

    test('rankFocusesGlobal orders focuses by most-recent authored thread',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final focusA = Uuid.generate();
      final focusB = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);

      // Oldest authored thread filed in focus A.
      final t1 = Uuid.generate();
      await _insertThread(store, t1,
          priorityId: focusA, contacts: [self], createdAt: DateTime(2026, 1, 1));
      await _insertNote(store, t1, author: self);

      // Most-recent authored thread filed in focus B.
      final t2 = Uuid.generate();
      await _insertThread(store, t2,
          priorityId: focusB,
          contacts: [self, greg],
          createdAt: DateTime(2026, 3, 1));
      await _insertNote(store, t2, author: self);

      // A second, older thread also in focus A — must not duplicate A.
      final t3 = Uuid.generate();
      await _insertThread(store, t3,
          priorityId: focusA, contacts: [self], createdAt: DateTime(2026, 2, 1));
      await _insertNote(store, t3, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);

      final ranked = await bloc.rankFocusesGlobal();
      // Most-recent first (focus B at 2026-03), then focus A (2026-02), deduped.
      expect(ranked, [focusB, focusA]);
    });

    test('rankFocusesGlobal returns empty when the user has no authored threads',
        () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);

      expect(await bloc.rankFocusesGlobal(), isEmpty);
    });

    test('search("a@b.com") lists address-capable connections', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      // A channel-only connector (Slack thread) must NOT appear for an email
      // query — it isn't address-capable.
      await _insertConnector(
        store,
        name: 'Slack (Acme)',
        linkType: 'thread',
        targets: 'channels',
        channelId: 'C1',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      final results = await bloc.search('someone@example.com');
      // Address-capable Gmail connection is offered, plus a Plot Chat option
      // pinned at the top (start a chat inviting the typed address).
      expect(results, isNotEmpty);
      // The connector entries are all the address-capable Gmail connection.
      final connectors =
          results.where((t) => t.kind == ComposeTargetKind.connector).toList();
      expect(connectors, isNotEmpty);
      expect(
        connectors.every((t) => t.connection?.id == gmail),
        isTrue,
        reason: 'only address-capable connections should be returned',
      );
    });

    test('search(unseen email) offers a Plot Chat inviting that address '
        'pinned above connectors', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      final results = await bloc.search('new@unseen.com');
      // The very first result is a Plot Chat carrying the unseen address as a
      // pending invite email (Personal scope, since the user has no teams).
      expect(results.first.kind, ComposeTargetKind.chat);
      expect(results.first.teamId, isNull);
      expect(results.first.inviteEmails, ['new@unseen.com']);
      expect(results.first.contacts, isEmpty);
      // Its signature folds in the invite email so it dedups distinctly from
      // the bare "Chat" template.
      expect(
        results.first.signature,
        composeChatSignature(null, inviteEmails: const ['new@unseen.com']),
      );
      // The chat is pinned above the address-capable connector(s).
      final chatIndex =
          results.indexWhere((t) => t.kind == ComposeTargetKind.chat);
      final connectorIndex =
          results.indexWhere((t) => t.connection?.id == gmail);
      expect(chatIndex, 0);
      expect(connectorIndex, greaterThan(chatIndex));
    });

    test('search(known contact email) offers a Plot Chat carrying that contact',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      // Resolve actors so the email search can match Greg by address.
      await Actor.get(self: true);
      await Actor.get();

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      // _insertActor derives the email from the name.
      final results = await bloc.search('greg.smith@x.test');
      final chat =
          results.firstWhere((t) => t.kind == ComposeTargetKind.chat);
      // The chat carries the matched contact as a roster contact, with no
      // pending invite email.
      expect(chat.contacts, [greg]);
      expect(chat.inviteEmails, isEmpty);
      // It renders the contact's display name as its detail.
      expect(chat.label, 'Chat · Greg Smith');
    });

    test(
        'base list has no duplicate signatures or labels; a connector with '
        'multiple bare-roster recent threads collapses to one entry', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );

      // Several recent authored Gmail DM threads, each to a DIFFERENT
      // correspondent whose contact is NOT in the Actor cache (never inserted
      // as an actor). Each thread derives a distinct roster signature, but
      // none resolves to a visible contact detail — so before the fix every
      // one produced its own identical bare "Gmail" row. They must collapse to
      // a single Gmail entry.
      for (var i = 0; i < 5; i++) {
        final correspondent = Uuid.generate(); // uncached → no detail
        final thread = Uuid.generate();
        await _insertThread(store, thread,
            priorityId: Uuid.generate(),
            contacts: [self, correspondent],
            createdAt: DateTime(2026, 5, 1).add(Duration(days: i)));
        await _insertNote(store, thread, author: self);
        await _insertLink(store, thread,
            createdBy: gmail, type: 'email', channelId: null);
      }

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      await bloc.refresh();

      final targets = bloc.state.targets;
      final sigs = targets.map((t) => t.signature).toList();
      final labels = targets.map((t) => t.label).toList();

      // No two entries share a signature...
      expect(sigs.toSet().length, sigs.length,
          reason: 'base list must not contain duplicate signatures');
      // ...and no two entries render with an identical label (the user-visible
      // dedup the picker depends on).
      expect(labels.toSet().length, labels.length,
          reason: 'base list must not contain visually identical rows');

      // Exactly one entry for the Gmail connection (the bare template), not
      // one per recent bare-roster DM thread.
      final gmailEntries =
          targets.where((t) => t.connection?.id == gmail).toList();
      expect(gmailEntries, hasLength(1),
          reason: 'bare-roster DM combos collapse onto the single template');
      expect(gmailEntries.single.label, 'Gmail');
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Builds a real [CreateTarget] for label tests without a store. Uses a DM /
/// address compose config (no channel) so [CreateTarget.isDmType] is true.
CreateTarget _fakeCreateTarget({
  required String name,
  required String linkType,
  required String targets,
}) {
  final twist = TwistInstance(
    TwistInstanceRow(
      id: Uuid.generate(),
      twistId: BigInt.from(100),
      twistEnvironment: 'test',
      draft: false,
      isSource: true,
      shared: false,
      name: name,
      handle: '',
      config: const {},
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      defaultMentionCreated: false,
      defaultMentionMentioned: false,
      userConnected: false,
      isBuiltin: false,
      multipleInstances: false,
    ),
  );
  final config = LinkTypeConfig(
    type: linkType,
    label: 'Email',
    compose: ComposeConfig(targets: targets, status: 'open'),
  );
  return CreateTarget(
    twist: twist,
    channel: null,
    linkType: config,
    compose: config.compose!,
    defaultStatus: const LinkStatus(status: 'open', label: 'Open'),
  );
}

Future<void> _insertActor(
  Store store,
  Uuid id, {
  required String name,
  bool self = false,
}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(ActorId(id)),
          type: const Value(ActorType.contact),
          name: Value(name),
          email: Value('${name.replaceAll(' ', '.').toLowerCase()}@x.test'),
          self: Value(self),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<void> _insertThread(
  Store store,
  Uuid id, {
  required Uuid priorityId,
  required List<Uuid> contacts,
  DateTime? createdAt,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(id),
          priorityId: Value(priorityId),
          contacts: Value(contacts),
          draft: const Value(false),
          createdAt:
              createdAt == null ? const Value.absent() : Value(createdAt),
        ),
      );
}

Future<void> _insertNote(
  Store store,
  Uuid threadId, {
  required Uuid author,
}) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(Uuid.generate()),
          threadId: Value(threadId),
          authorId: Value(ActorId(author)),
          sourceCreatedAt: Value(DateTime(2026, 1, 1)),
        ),
      );
}

Future<void> _insertLink(
  Store store,
  Uuid threadId, {
  required Uuid createdBy,
  required String type,
  String? channelId,
}) async {
  await store.into(store.links).insert(
        LinksCompanion(
          id: Value(Uuid.generate()),
          threadId: Value(threadId),
          createdBy: Value(createdBy),
          type: Value(type),
          channelId: Value(channelId),
          sourceCreatedAt: Value(DateTime(2026, 1, 1)),
        ),
      );
}

Future<void> _insertTeamUser(
  Store store, {
  required BigInt teamId,
  required String name,
}) async {
  await store.into(store.teamUsers).insert(
        TeamUsersCompanion(
          id: Value(teamId),
          userId: const Value('user'),
          teamId: Value(teamId),
          role: const Value('member'),
          teamName: Value(name),
        ),
      );
}

/// Inserts a connector connection (twist_instance + one enabled channel whose
/// linkTypes declare a compose block) and registers the instance in the
/// in-memory caches that [loadCreateTargets] / [Link.getTypeConfig] read.
/// Returns the connection's (twist_instance) id.
Future<Uuid> _insertConnector(
  Store store, {
  required String name,
  required String linkType,
  required String targets,
  String channelId = 'default',
}) async {
  final instanceId = Uuid.generate();
  final linkTypesJson = jsonEncode([
    {
      'type': linkType,
      'label': linkType == 'email' ? 'Email' : 'Thread',
      'compose': {'targets': targets, 'status': 'open'},
    }
  ]);

  await store.into(store.twistInstances).insert(
        TwistInstancesCompanion(
          id: Value(instanceId),
          twistId: Value(BigInt.from(name.hashCode & 0x7fffffff)),
          twistEnvironment: const Value('test'),
          isSource: const Value(true),
          name: Value(name),
          config: const Value(<String, dynamic>{}),
          linkTypes: Value(linkTypesJson),
        ),
      );
  // Populate the TwistInstance cache (loadCreateTargets / getTypeConfig read it
  // synchronously via fromCache).
  await TwistInstance.get();

  await store.into(store.channels).insert(
        ChannelsCompanion(
          id: Value(BigInt.from(channelId.hashCode & 0x7fffffff)),
          twistInstanceId: Value(instanceId),
          channelId: Value(channelId),
          title: Value('$name channel'),
          enabled: const Value(true),
          linkTypes: Value(linkTypesJson),
        ),
      );
  // Populate the Channel cache (findByChannel / findBySource read it).
  final channels = await Channel.getAllEnabled();
  Channel.populateCache(channels);

  return instanceId;
}
