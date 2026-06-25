import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/types.dart' show ContactExternalAccount;
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/widget/compose/compose_pill.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/compose/compose_target_view.dart';
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

    test('connector signature folds in pending invite emails (sorted) so a '
        'connector inviting an address dedups distinctly from bare', () {
      final instance = Uuid.generate();
      final bare = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
      );
      final withInvite = composeConnectorSignature(
        twistInstanceId: instance.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        inviteEmails: const ['B@x.com', 'a@x.com'],
      );
      expect(withInvite, '$bare:e=a@x.com,b@x.com');
      expect(withInvite, isNot(bare));
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

    test('focusNote signature is keyed per focus and per scope', () {
      final a = Uuid.generate();
      final b = Uuid.generate();
      final team = BigInt.from(7);
      // Same focus + scope → identical signature.
      expect(
        ComposeTarget.focusNote(priorityId: a, teamId: null).signature,
        ComposeTarget.focusNote(priorityId: a, teamId: null).signature,
      );
      // Different focus → distinct.
      expect(
        ComposeTarget.focusNote(priorityId: a, teamId: null).signature,
        isNot(ComposeTarget.focusNote(priorityId: b, teamId: null).signature),
      );
      // Same focus, different scope → distinct.
      expect(
        ComposeTarget.focusNote(priorityId: a, teamId: null).signature,
        isNot(ComposeTarget.focusNote(priorityId: a, teamId: team).signature),
      );
      expect(
        ComposeTarget.focusNote(priorityId: a, teamId: null).signature,
        'note:personal:p=$a',
      );
    });
  });

  group('connectionColorKey', () {
    test('Plot chat/note key is per scope (Personal vs each team)', () {
      expect(
        connectionColorKey(ComposeTarget.chat(teamId: null, hasTeams: true)),
        'plot:personal',
      );
      expect(
        connectionColorKey(
            ComposeTarget.chat(teamId: BigInt.from(7), hasTeams: true)),
        'plot:7',
      );
      // A focus-note (note kind) keys by its scope too — a work team's colour
      // stays distinct from personal.
      expect(
        connectionColorKey(
            ComposeTarget.focusNote(priorityId: Uuid.generate(), teamId: null)),
        'plot:personal',
      );
    });
  });

  group('composeSignatureForScanThread (recent-thread derivation)', () {
    test('link-less thread → note when no roster, chat when roster', () {
      final team = BigInt.from(3);
      final c = Uuid.generate();

      final note = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(teamId: team, priorityId: Uuid.generate()),
      );
      expect(note, composeNoteSignature(team));

      final chat = ComposeTargetsBloc.composeSignatureForScanThread(
        ComposeScanThread(teamId: team, contacts: [c], priorityId: Uuid.generate()),
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
          priorityId: Uuid.generate(),
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
          priorityId: Uuid.generate(),
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
          priorityId: Uuid.generate(),
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
        ComposeScanThread(teamId: team, contacts: [c], priorityId: Uuid.generate()), // chat:1:c=...
        ComposeScanThread(teamId: team, priorityId: Uuid.generate()), // note:1
        ComposeScanThread(teamId: team, contacts: [c], priorityId: Uuid.generate()), // dup of first
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
      addTearDown(bloc.close);

      final note = ComposeTarget.note(hasTeams: false);
      final chat = ComposeTarget.chat(hasTeams: false);
      bloc.prependToCache(note);
      bloc.prependToCache(chat);
      expect(bloc.state.targets.map((v) => v.target.signature),
          [chat.signature, note.signature]);

      // Re-recording note moves it to the front without duplicating.
      bloc.prependToCache(note);
      expect(bloc.state.targets.map((v) => v.target.signature),
          [note.signature, chat.signature]);
      expect(bloc.state.targets.length, 2);
    });

    test('recordTarget records the signature in the connection MRU', () async {
      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);

      final chat = ComposeTarget.chat(hasTeams: false);
      await bloc.recordTarget(chat);

      expect(prefs.lastUsedMsForSignature(chat.signature), isNotNull);
      expect(bloc.state.targets.first.target.signature, chat.signature);
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
        'base list surfaces per-connection templates; used combos (rostered '
        'chat + connector DM) rank ahead by recency', () async {
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

      // One team membership (scopes the rostered chat combo to Personal).
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
      addTearDown(bloc.close);
      await bloc.refresh();

      final labels = bloc.state.targets.map((v) => v.target.label).toList();
      final sigs = bloc.state.targets.map((v) => v.target.signature).toList();

      // The generic Note/Chat templates are gone (replaced by focus-note +
      // twist targets); a no-roster Plot thread no longer yields its own row.
      expect(labels, isNot(contains('Note (Personal)')));
      expect(labels, isNot(contains('Chat (Personal)')));
      expect(labels, isNot(contains('Note (Acme)')));
      expect(labels, isNot(contains('Chat (Acme)')));

      // Bare DM-type connector templates (a contactless "Gmail") are no longer
      // offered — a Gmail row only appears carrying a contact, so the bare
      // Gmail signature is absent; only the Gmail-with-Greg combo (below) shows.
      expect(sigs, isNot(contains(
        composeConnectorSignature(
          twistInstanceId: gmail.toString(),
          channelId: null,
          linkType: 'email',
          dmTargets: 'addresses',
        ),
      )));

      // The used combos (Gmail-with-Greg DM, then native chat-with-Greg) rank
      // ahead of the templates, most-recent first.
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
      // combos render *distinctly* (the roster is surfaced in the label).
      final byLabel = {
        for (final v in bloc.state.targets) v.target.signature: v.target.label
      };
      expect(byLabel[gmailGregSig], 'Gmail · Greg Smith');
      expect(byLabel[chatGregSig], 'Chat (Personal) · Greg Smith');
      // No two rows render identically.
      expect(labels.toSet().length, labels.length);
    });

    test('search("") and search("   ") return the cached base list', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      // A used Gmail+Greg combo makes the base list non-empty. (Bare DM-type
      // connector templates are no longer offered, so a connection only shows
      // once it carries a contact.)
      final gmail = await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final dmThread = Uuid.generate();
      await _insertThread(store, dmThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, dmThread, author: self);
      await _insertLink(store, dmThread,
          createdBy: gmail, type: 'email', channelId: null);
      final comboSig = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [greg],
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // The base list the step-1 TargetPickerList re-seeds from when refresh()
      // emits with an empty query.
      final baseSigs =
          bloc.state.targets.map((v) => v.target.signature).toList();
      expect(baseSigs, contains(comboSig));

      // An empty (and a blank/whitespace-only) query falls back to that cached
      // base list rather than returning [].
      final emptySigs =
          (await bloc.search('')).map((v) => v.target.signature).toList();
      final blankSigs =
          (await bloc.search('   ')).map((v) => v.target.signature).toList();
      expect(emptySigs, baseSigs);
      expect(blankSigs, baseSigs);
      expect(emptySigs, contains(comboSig));
    });

    test('search("greg") ranks the used connection first, then offers every '
        'other way to reach the contact; excludes non-inviteable addresses',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate(); // a normal, inviteable contact
      final noreply = Uuid.generate(); // a non-inviteable no-reply address
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, noreply, name: 'Greg Noreply', inviteable: false);
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

      // An inbound thread from the non-inviteable "Greg Noreply" address.
      final noreplyThread = Uuid.generate();
      await _insertThread(store, noreplyThread,
          priorityId: priorityId,
          contacts: [self, noreply],
          createdAt: DateTime(2026, 5, 2));

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.search('greg');
      final sigs = results.map((v) => v.target.signature).toList();

      // The connection actually used with Greg (Gmail) is offered and ranks
      // first (used connections win over freshly-synthesized ones).
      final gregCombo = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [greg],
      );
      expect(sigs, contains(gregCombo));
      expect(sigs.first, gregCombo);

      // Plus every OTHER way to reach Greg — e.g. a Plot chat — even though it
      // was never used with them, so you can message them via a new connection.
      expect(sigs, contains(composeChatSignature(null, contacts: [greg])));

      // The non-inviteable "Greg Noreply" address is filtered out — no combo
      // (used or synthesized) references it.
      final noreplyCombo = composeConnectorSignature(
        twistInstanceId: gmail.toString(),
        channelId: null,
        linkType: 'email',
        dmTargets: 'addresses',
        contacts: [noreply],
      );
      expect(sigs, isNot(contains(noreplyCombo)));
    });

    test('a Plot chat shared with a group renders the group name', () async {
      final self = Uuid.generate();
      final groupId = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);
      await _insertGroup(store, groupId, name: 'Acme Team');

      // A self-authored Plot chat shared with the group (no individual
      // contacts beyond the author).
      final chatThread = Uuid.generate();
      await _insertThread(store, chatThread,
          priorityId: priorityId,
          contacts: [self],
          groups: [groupId],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, chatThread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // The group chat surfaces with the group's name as a recipient (rather
      // than collapsing to a bare "Chat" label).
      final chatSig = composeChatSignature(null, groups: [groupId]);
      final view = bloc.state.targets
          .firstWhere((v) => v.target.signature == chatSig);
      expect(view.recipients.map((r) => r.name), contains('Acme Team'));
    });

    test(
        'loadSections at-rest people list drops non-inviteable roster contacts',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate(); // inviteable correspondent
      final daemon = Uuid.generate(); // bounced mailer-daemon (non-inviteable)
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, daemon,
          name: 'Mail Delivery Subsystem', inviteable: false);
      await Actor.get(self: true);

      // An authored thread whose roster mixes Greg with a bounced
      // mailer-daemon address — the shape that leaked daemons into the
      // picker before the inviteable filter.
      final thread = Uuid.generate();
      await _insertThread(store, thread,
          priorityId: priorityId,
          contacts: [self, greg, daemon],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, thread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.loadSections();
      final peopleContacts = sections.people
          .expand((e) => e.contacts.map((u) => u.toString()))
          .toSet();

      // The daemon used to ride along on the {Greg} roster; now only Greg
      // surfaces and the roster collapses to a single-contact pill.
      expect(peopleContacts, contains(greg.toString()));
      expect(peopleContacts, isNot(contains(daemon.toString())));
    });

    test('loadSections drops non-inviteable members from a group pill preview',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate(); // inviteable member
      final daemon = Uuid.generate(); // non-inviteable member
      final groupId = Uuid.generate();
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, daemon, name: 'Mailer Daemon', inviteable: false);
      await Actor.get(self: true);
      // The group thread carries no individual contacts, so the context's
      // own cache-warm is skipped — warm the members explicitly the way a
      // real session does via the global actor sync.
      await Actor.get();
      await _insertGroup(store, groupId,
          name: 'Acme Team', memberContactIds: [greg, daemon]);

      final chatThread = Uuid.generate();
      await _insertThread(store, chatThread,
          priorityId: priorityId,
          contacts: [self],
          groups: [groupId],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, chatThread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.loadSections();
      final groupEntry = sections.people.firstWhere((e) => e.hasGroup);
      final memberIds = (groupEntry.display as GroupPillData)
          .members
          .map((a) => a.id.toUuid().toString())
          .toSet();

      expect(memberIds, contains(greg.toString()));
      expect(memberIds, isNot(contains(daemon.toString())));
    });

    test(
        'loadSections collapses a group filed across threads with differing '
        'participant sets to a single People row', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final bob = Uuid.generate();
      final groupId = Uuid.generate();
      final priorityId = Uuid.generate();

      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, bob, name: 'Bob Jones');
      await Actor.get(self: true);
      await Actor.get();
      await _insertGroup(store, groupId,
          name: 'Acme Team', memberContactIds: [greg, bob]);

      // Three authored threads to the SAME group, each carrying a DIFFERENT set
      // of incidental participants — the shape that produced repeated identical
      // "Plot Team" rows. The group pill ignores these contacts, so all three
      // must collapse to one entry.
      final rosters = [
        [self],
        [self, greg],
        [self, bob],
      ];
      for (var i = 0; i < rosters.length; i++) {
        final t = Uuid.generate();
        await _insertThread(store, t,
            priorityId: priorityId,
            contacts: rosters[i],
            groups: [groupId],
            createdAt: DateTime(2026, 5, 1 + i));
        await _insertNote(store, t, author: self);
      }

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.loadSections();
      final groupEntries = sections.people.where((e) => e.hasGroup).toList();
      expect(groupEntries, hasLength(1),
          reason: 'the same group must surface as one row regardless of the '
              'per-thread participant sets');
      // And it carries only the group — incidental contacts are dropped.
      expect(groupEntries.single.contacts, isEmpty);
      expect(groupEntries.single.groups, [groupId]);
    });

    test(
        'loadSections dedupes a single-instance builtin twist that has two '
        'instances (e.g. Plot AI + the synthetic Plot Team sender)', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      // Two instances of the SAME builtin twist (same twistId), both exposing
      // the same "Plot AI chat" thread type and not allowing multiple
      // instances — the user's "Plot" instance and the synthetic "Plot Team"
      // system sender.
      final sharedTwistId = BigInt.from(600);
      await _insertChatTwist(store,
          name: 'Plot', threadType: 'Plot AI chat', twistId: sharedTwistId);
      await _insertChatTwist(store,
          name: 'Plot Team', threadType: 'Plot AI chat', twistId: sharedTwistId);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.loadSections();
      final chatRows =
          sections.twists.where((t) => t.label == 'Plot AI chat').toList();
      expect(chatRows, hasLength(1),
          reason: 'a single-instance twist surfaces once even with two '
              'instances in the store');
    });

    test(
        'loadSections keeps every instance of a multi-instance twist', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final sharedTwistId = BigInt.from(700);
      await _insertChatTwist(store,
          name: 'Assistant A',
          threadType: 'AI chat',
          twistId: sharedTwistId,
          multipleInstances: true);
      await _insertChatTwist(store,
          name: 'Assistant B',
          threadType: 'AI chat',
          twistId: sharedTwistId,
          multipleInstances: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.loadSections();
      final headers = sections.twists.map((t) => t.twistHeader).toSet();
      expect(headers, containsAll(['Assistant A', 'Assistant B']),
          reason: 'multi-instance twists must each keep their own row');
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
      addTearDown(bloc.close);
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
      expect(stale.map((v) => v.target.signature), isNot(contains(gregCombo)),
          reason: 'search must not re-scan the store on every keystroke');

      // refresh() invalidates the cache; the next search rebuilds from fresh
      // data and now surfaces the combo.
      await bloc.refresh();
      final fresh = await bloc.search('greg');
      expect(fresh.map((v) => v.target.signature), contains(gregCombo),
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
      addTearDown(bloc.close);

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
      addTearDown(bloc.close);

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
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.search('someone@example.com');
      // Address-capable Gmail connection is offered, plus a Plot Chat option
      // pinned at the top (start a chat inviting the typed address).
      expect(results, isNotEmpty);
      // The connector entries are all the address-capable Gmail connection.
      final connectors = results
          .where((v) => v.target.kind == ComposeTargetKind.connector)
          .toList();
      expect(connectors, isNotEmpty);
      expect(
        connectors.every((v) => v.target.connection?.id == gmail),
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
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.search('new@unseen.com');
      // The very first result is a Plot Chat carrying the unseen address as a
      // pending invite email (Personal scope, since the user has no teams).
      expect(results.first.target.kind, ComposeTargetKind.chat);
      expect(results.first.target.teamId, isNull);
      expect(results.first.target.inviteEmails, ['new@unseen.com']);
      expect(results.first.target.contacts, isEmpty);
      // Its signature folds in the invite email so it dedups distinctly from
      // the bare "Chat" template.
      expect(
        results.first.target.signature,
        composeChatSignature(null, inviteEmails: const ['new@unseen.com']),
      );
      // The chat is pinned above the address-capable connector(s).
      final chatIndex =
          results.indexWhere((v) => v.target.kind == ComposeTargetKind.chat);
      final connectorIndex =
          results.indexWhere((v) => v.target.connection?.id == gmail);
      expect(chatIndex, 0);
      expect(connectorIndex, greaterThan(chatIndex));
    });

    test('search(unseen email) carries the address onto connector entries too',
        () async {
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
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.search('new@unseen.com');
      // The address-capable connector entry carries the typed address through
      // to compose, exactly like the pinned Plot Chat does — so picking Gmail
      // for a brand-new address sends to it instead of composing a private,
      // recipientless thread.
      final connector =
          results.firstWhere((v) => v.target.connection?.id == gmail);
      expect(connector.target.inviteEmails, const ['new@unseen.com']);
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
      addTearDown(bloc.close);
      await bloc.refresh();

      // _insertActor derives the email from the name.
      final results = await bloc.search('greg.smith@x.test');
      final chat = results
          .firstWhere((v) => v.target.kind == ComposeTargetKind.chat)
          .target;
      // The chat carries the matched contact as a roster contact, with no
      // pending invite email.
      expect(chat.contacts, [greg]);
      expect(chat.inviteEmails, isEmpty);
      // The label is the bare "Chat" template (no teams here, and the roster is
      // no longer folded into the label — recipient presentation comes from the
      // view layer); the matched contact is surfaced via [contacts] above.
      expect(chat.label, 'Chat');
    });

    test(
        'searchSections(known contact email) surfaces a People entry carrying '
        'that contact', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // _insertActor derives the email from the name.
      final sections = await bloc.searchSections('greg.smith@x.test');
      // A single People entry resolving the typed address to the known contact,
      // with no pending invite. The connection is chosen in step 2.
      expect(sections.people, hasLength(1));
      final entry = sections.people.single;
      expect(entry.contacts, [greg]);
      expect(entry.inviteEmails, isEmpty);
    });

    test(
        'searchSections(unseen email) surfaces a People entry carrying a '
        'pending invite', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final sections = await bloc.searchSections('new@unseen.com');
      // An unmatched address becomes a pending invite on the roster (no
      // contact), so the user can start a thread inviting it.
      expect(sections.people, hasLength(1));
      final entry = sections.people.single;
      expect(entry.contacts, isEmpty);
      expect(entry.inviteEmails, ['new@unseen.com']);
    });

    test(
        'searchSections(multiple addresses) collapses them into one People '
        'entry mixing known contacts and invites', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // One known contact + one unseen address, comma-separated.
      final sections =
          await bloc.searchSections('greg.smith@x.test, new@unseen.com');
      expect(sections.people, hasLength(1),
          reason: 'typed addresses collapse into one ad-hoc roster entry');
      final entry = sections.people.single;
      expect(entry.contacts, [greg]);
      expect(entry.inviteEmails, ['new@unseen.com']);
    });

    test(
        'searchSections(twist name) surfaces the twist row even though its '
        'thread-type label differs from the name', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      // A chat twist whose name is "Plot" but whose thread-type label (the
      // row's content line, also [ComposeTarget.label]) is "Plot AI chat".
      await _insertChatTwist(store, name: 'Plot', threadType: 'Plot AI chat');

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // Typing the twist's NAME must match: the filter checks [twistHeader]
      // (the name), not just [label] (the thread type).
      final byName = await bloc.searchSections('Plot');
      expect(byName.twists.map((t) => t.twistHeader), contains('Plot'),
          reason: 'a twist must be findable by its name, not only its '
              'thread-type label');

      // And the existing thread-type match still works.
      final byType = await bloc.searchSections('AI chat');
      expect(byType.twists.map((t) => t.twistHeader), contains('Plot'));
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
      addTearDown(bloc.close);
      await bloc.refresh();

      final targets = bloc.state.targets;
      final sigs = targets.map((v) => v.target.signature).toList();
      final labels = targets.map((v) => v.target.label).toList();

      // No two entries share a signature...
      expect(sigs.toSet().length, sigs.length,
          reason: 'base list must not contain duplicate signatures');
      // ...and no two entries render with an identical label (the user-visible
      // dedup the picker depends on).
      expect(labels.toSet().length, labels.length,
          reason: 'base list must not contain visually identical rows');

      // Exactly one connector entry for the Gmail connection (the bare
      // template), not one per recent bare-roster DM thread. (The connection's
      // twist_instance is a source/connector, so the chatTwists filter excludes
      // it from the twist rows — Gmail appears only as this connector entry.)
      final gmailConnectorEntries = targets
          .where((v) =>
              v.target.kind == ComposeTargetKind.connector &&
              v.target.connection?.id == gmail)
          .toList();
      expect(gmailConnectorEntries, hasLength(1),
          reason: 'bare-roster DM combos collapse onto the single template');
      expect(gmailConnectorEntries.single.target.label, 'Gmail');
    });

    test(
        'auto-refreshes when a connection is added mid-session (no explicit '
        'refresh) so new options appear without an app restart', () async {
      final self = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await Actor.get(self: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      // Bloc starts against an empty connection store; it subscribes to channel
      // / twist-instance changes in its constructor. Let the initial reactive
      // refresh settle (past the debounce window).
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        bloc.state.targets
            .where((v) => v.target.kind == ComposeTargetKind.connector),
        isEmpty,
        reason: 'no connections yet → no connector rows',
      );

      // Add a channel connector AFTER the bloc was built — the regression case
      // (previously only an app restart surfaced it).
      final slack = await _insertConnector(
        store,
        name: 'Slack',
        linkType: 'thread',
        targets: 'channels',
      );

      // Without calling bloc.refresh(): the channel write drives the watch
      // stream, and the debounced reactive refresh rebuilds the base list.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final slackConnector = bloc.state.targets.where((v) =>
          v.target.kind == ComposeTargetKind.connector &&
          v.target.connection?.id == slack);
      expect(slackConnector, isNotEmpty,
          reason: 'a connection added mid-session must appear automatically');
    });

    test(
        'lastUsedTargetForRoster returns the connection last used with an '
        'exact roster', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      // One authored Plot chat to Greg.
      final chatThread = Uuid.generate();
      await _insertThread(store, chatThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, chatThread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final target = await bloc.lastUsedTargetForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );
      expect(target, isNotNull);
      expect(target!.signature, composeChatSignature(null, contacts: [greg]));
    });

    test(
        'lastUsedTargetForRoster returns the most-recently-used connection when '
        'a roster has several', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      final gmail = await _insertConnector(store,
          name: 'Gmail (kris@plot.day)',
          linkType: 'email',
          targets: 'addresses');

      // Older: Gmail DM to Greg.
      final dmThread = Uuid.generate();
      await _insertThread(store, dmThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, dmThread, author: self);
      await _insertLink(store, dmThread,
          createdBy: gmail, type: 'email', channelId: null);

      // Newer: Plot chat to Greg.
      final chatThread = Uuid.generate();
      await _insertThread(store, chatThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 2));
      await _insertNote(store, chatThread, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final target = await bloc.lastUsedTargetForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );
      expect(target!.signature, composeChatSignature(null, contacts: [greg]),
          reason: 'the newer Plot chat wins over the older Gmail DM');
    });

    test(
        'lastUsedTargetForRoster returns null for a sub-roster of a past thread',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final bob = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await _insertActor(store, bob, name: 'Bob Jones');
      await Actor.get(self: true);
      await Actor.get();

      // Only a {Greg, Bob} thread exists.
      final t = Uuid.generate();
      await _insertThread(store, t,
          priorityId: priorityId,
          contacts: [self, greg, bob],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, t, author: self);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      // Picking just {Greg} must not borrow the {Greg, Bob} connection.
      final target = await bloc.lastUsedTargetForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );
      expect(target, isNull);
    });

    test('lastUsedTargetForRoster returns null when the roster has no history',
        () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final target = await bloc.lastUsedTargetForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );
      expect(target, isNull);
    });

    test(
        'lastUsedTargetForRoster returns null when the remembered connection is '
        'no longer available', () async {
      final self = Uuid.generate();
      final greg = Uuid.generate();
      final priorityId = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, greg, name: 'Greg Smith');
      await Actor.get(self: true);
      await Actor.get();

      // A Gmail DM thread to Greg, but the Gmail connection itself is gone
      // (no twist_instance/channel registered), so no live template resolves
      // for the combo — the realistic "connection removed" case.
      final goneInstance = Uuid.generate();
      final dmThread = Uuid.generate();
      await _insertThread(store, dmThread,
          priorityId: priorityId,
          contacts: [self, greg],
          createdAt: DateTime(2026, 5, 1));
      await _insertNote(store, dmThread, author: self);
      await _insertLink(store, dmThread,
          createdBy: goneInstance, type: 'email', channelId: null);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final target = await bloc.lastUsedTargetForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );
      expect(target, isNull,
          reason: 'a removed connection must fall back to the connection step');
    });

    test('connectionsForRoster offers email (addresses) connectors for a group '
        'and carries the group onto the target, excluding contacts-type DMs',
        () async {
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      await _insertConnector(
        store,
        name: 'Slack (Acme)',
        linkType: 'dm',
        targets: 'contacts',
        channelId: 'slack-default',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final groupId = Uuid.generate();
      final results = await bloc.connectionsForRoster(
        contacts: const [],
        groups: [groupId],
        inviteEmails: const [],
      );

      final connectorTargets =
          results.where((t) => t.target != null).toList();
      // The addresses connector is offered...
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'addresses'),
        isTrue,
      );
      // ...and carries the group through to the created thread.
      final addr = connectorTargets
          .firstWhere((t) => t.target!.compose.targets == 'addresses');
      expect(addr.groups, contains(groupId));
      // The contacts-type DM connector is NOT offered for a group.
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'contacts'),
        isFalse,
      );
    });

    test('connectionsForRoster with no group offers all DM-type connectors '
        '(contacts + addresses)', () async {
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      await _insertConnector(
        store,
        name: 'Slack (Acme)',
        linkType: 'dm',
        targets: 'contacts',
        channelId: 'slack-default',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: const [],
        groups: const [],
        inviteEmails: const [],
      );

      final connectorTargets = results.where((t) => t.target != null).toList();
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'addresses'),
        isTrue,
      );
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'contacts'),
        isTrue,
      );
    });

    test('connectionsForRoster carries a pending invite email onto connector '
        'targets so the typed address reaches compose', () async {
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: const [],
        groups: const [],
        inviteEmails: const ['new@unseen.com'],
      );

      // The address-capable Gmail connection carries the typed email through to
      // compose, so the thread is addressed to it (shared, with the address as
      // a pending invite) rather than landing private with no recipient.
      final addr = results.firstWhere((t) =>
          t.kind == ComposeTargetKind.connector &&
          t.target!.compose.targets == 'addresses');
      expect(addr.inviteEmails, const ['new@unseen.com']);
    });

    test('hides connections that cannot reach the contact — only the LinkedIn '
        'DM is offered for a LinkedIn-only contact (no email, not a Plot user)',
        () async {
      final linkedinId = await _insertConnector(
        store,
        name: 'LinkedIn',
        linkType: 'dm',
        targets: 'contacts',
        channelId: 'li-default',
      );
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final self = Uuid.generate();
      final danylo = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(
        store,
        danylo,
        name: 'Danylo Bukur',
        noEmail: true,
        externalAccounts: [
          ContactExternalAccount(
            twistInstanceId: linkedinId,
            accountId: 'li-acc',
            provider: 'linkedin',
          ),
        ],
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: [danylo],
        groups: const [],
        inviteEmails: const [],
      );

      // Only the LinkedIn (contacts) connector can reach Danylo.
      final connectorTargets = results.where((t) => t.target != null).toList();
      expect(connectorTargets, hasLength(1));
      expect(connectorTargets.single.target!.compose.targets, 'contacts');
      expect(connectorTargets.single.target!.twist.name, 'LinkedIn');
      // Gmail (addresses) is not offered — Danylo has no email.
      expect(
        results.any((t) => t.target?.compose.targets == 'addresses'),
        isFalse,
      );
      // Plot chat is not offered — Danylo is not a Plot user and has no email.
      expect(results.any((t) => t.kind == ComposeTargetKind.chat), isFalse);
    });

    test('offers Plot + Gmail but hides the LinkedIn DM for an email contact '
        'not bound to LinkedIn', () async {
      await _insertConnector(
        store,
        name: 'LinkedIn',
        linkType: 'dm',
        targets: 'contacts',
        channelId: 'li-default',
      );
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final self = Uuid.generate();
      final greg = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      // Greg has an email (derived from name) and no LinkedIn account.
      await _insertActor(store, greg, name: 'Greg Smith');

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: [greg],
        groups: const [],
        inviteEmails: const [],
      );

      // Gmail (addresses) reaches Greg by email; Plot can invite him by email.
      expect(
        results.any((t) => t.target?.compose.targets == 'addresses'),
        isTrue,
      );
      expect(results.any((t) => t.kind == ComposeTargetKind.chat), isTrue);
      // LinkedIn (contacts) is hidden — Greg has no LinkedIn account.
      expect(
        results.any((t) => t.target?.compose.targets == 'contacts'),
        isFalse,
      );
    });

    test('offers nothing for a contact with no email, not a Plot user, and no '
        'connection account', () async {
      await _insertConnector(
        store,
        name: 'LinkedIn',
        linkType: 'dm',
        targets: 'contacts',
        channelId: 'li-default',
      );
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final self = Uuid.generate();
      final ghost = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(store, ghost, name: 'No Reach', noEmail: true);

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: [ghost],
        groups: const [],
        inviteEmails: const [],
      );

      expect(results, isEmpty);
    });

    test('offers Plot chat for a Plot user even without an email, but not an '
        'email-only connection', () async {
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      final self = Uuid.generate();
      final teammate = Uuid.generate();
      await _insertActor(store, self, name: 'Me', self: true);
      await _insertActor(
        store,
        teammate,
        name: 'Team Mate',
        noEmail: true,
        type: ActorType.user,
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final results = await bloc.connectionsForRoster(
        contacts: [teammate],
        groups: const [],
        inviteEmails: const [],
      );

      // Plot chat reaches a Plot user directly.
      expect(results.any((t) => t.kind == ComposeTargetKind.chat), isTrue);
      // Gmail can't reach a user with no email address.
      expect(
        results.any((t) => t.target?.compose.targets == 'addresses'),
        isFalse,
      );
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
  bool inviteable = true,
  bool noEmail = false,
  ActorType type = ActorType.contact,
  List<ContactExternalAccount> externalAccounts = const [],
}) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(ActorId(id)),
          type: Value(type),
          name: Value(name),
          email: noEmail
              ? const Value<String?>(null)
              : Value('${name.replaceAll(' ', '.').toLowerCase()}@x.test'),
          self: Value(self),
          inviteable: Value(inviteable),
          primary: const Value(true),
          externalAccounts: Value(externalAccounts),
        ),
      );
}

Future<void> _insertThread(
  Store store,
  Uuid id, {
  required Uuid priorityId,
  required List<Uuid> contacts,
  List<Uuid> groups = const [],
  DateTime? createdAt,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(id),
          priorityId: Value(priorityId),
          contacts: Value(contacts),
          groups: Value(groups),
          draft: const Value(false),
          createdAt:
              createdAt == null ? const Value.absent() : Value(createdAt),
        ),
      );
}

Future<void> _insertGroup(
  Store store,
  Uuid id, {
  required String name,
  List<Uuid> memberContactIds = const [],
}) async {
  await store.into(store.groups).insert(
        GroupsCompanion(
          id: Value(id),
          name: Value(name),
          type: const Value('team'),
          joinPolicy: const Value('closed'),
          isMember: const Value(true),
          memberContactIds: Value(memberContactIds),
        ),
      );
  // Populate the synchronous Group cache (Group.fromCache) the way the picker
  // reads it.
  await Group.getOne(id);
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

/// Inserts a chat-capable twist instance (not a source/connector, with a
/// non-empty [threadType]) so it passes the `chatTwists` filter and appears as
/// a "chat with a twist" row. Returns the twist_instance id.
Future<Uuid> _insertChatTwist(
  Store store, {
  required String name,
  String threadType = 'AI chat',
  BigInt? twistId,
  bool multipleInstances = false,
}) async {
  final instanceId = Uuid.generate();
  await store.into(store.twistInstances).insert(
        TwistInstancesCompanion(
          id: Value(instanceId),
          twistId: Value(twistId ?? BigInt.from(name.hashCode & 0x7fffffff)),
          twistEnvironment: const Value('test'),
          isSource: const Value(false),
          name: Value(name),
          threadType: Value(threadType),
          multipleInstances: Value(multipleInstances),
          config: const Value(<String, dynamic>{}),
        ),
      );
  await TwistInstance.get();
  return instanceId;
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
