part of 'store.dart';

@DataClassName('ActorRow')
class Actors extends Table with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get id => blob().map(const ActorIdConverter())();
  TextColumn get type => text().map(const EnumConverter<ActorType>())();
  TextColumn get name => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  BoolColumn get self => boolean()();
  BoolColumn get inviteable => boolean().withDefault(const Constant(true))();
  /// The canonical actor for its underlying person/twist. Non-primary linked
  /// contacts (secondary email aliases) are returned so historical content
  /// authored by those IDs still resolves to a name, but they MUST be excluded
  /// from user-facing pickers (mentions, share, assignee).
  BoolColumn get primary => boolean().withDefault(const Constant(true))();
  /// The contact's underlying user_id (the human this contact identifies).
  /// Multiple contact rows on the same thread that share a [linkedUserId]
  /// represent the same person and are deduped in client-side rendering.
  /// NULL for unlinked external contacts and twist instances.
  BlobColumn get linkedUserId =>
      blob().nullable().map(const UuidConverter())();

  /// External messaging platform accounts mapped to this contact.
  /// Aggregated from the server's contact_external_account table and stored
  /// as a JSON array of {twist_instance_id, account_id, provider} objects.
  /// Always an empty list for twist instances. Used by the DM picker to
  /// filter contacts to those reachable via a specific connection
  /// (twist_instance_id). `provider` is display-only.
  TextColumn get externalAccounts =>
      text().withDefault(const Constant('[]')).map(const ExternalAccountListConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

class ActorsBase extends BaseTable {
  ActorsBase() : super(table: 'user_actor', syncEndpoint: 'actors');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Only contacts are writable from the client (add/rename). The server
    // rejects any other type. We send the minimal payload save_user_contact
    // consumes; everything else on the row is server-derived.
    final actor = row as ActorRow;
    return {
      'id': actor.id.toUuid().toString(),
      'type': 'contact',
      'email': actor.email,
      'name': actor.name,
    };
  }

  @override
  Insertable<ActorRow> fromBase(Map<String, dynamic> json) {
    return ActorRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // Contact id is server-owned (keyed on the globally-unique email). When the
    // server resolved an added email to an EXISTING contact, the optimistic row
    // AddContact inserted has a different id than the canonical row arriving
    // here. Email is unique server-side, so any LOCAL contact row with the same
    // email but a different id is a stale optimistic duplicate -- delete it
    // before this batch upserts the canonical row.
    final list = rows.toList();
    final tableName = store.actors.actualTableName;
    for (final r in list) {
      if (r is! ActorRow) continue;
      if (r.type != ActorType.contact || r.email == null) continue;
      await store.customStatement(
        'DELETE FROM $tableName WHERE lower(email) = lower(?) AND id != ?',
        [r.email, r.id.toBytes()],
      );
    }
    return list;
  }
}

class Actor extends ActorRow {
  static TableInfo<Actors, ActorRow> get table => Store.get.actors;

  // In-memory cache for Actor lookups
  static final Map<ActorId, Actor> _cache = {};

  /// Maps a contact's underlying user_id → the user's primary actor id.
  /// Built incrementally as actors are cached. Lets [canonicalId] collapse
  /// linked-contact aliases to the primary in O(1).
  static final Map<Uuid, ActorId> _primaryByUser = {};

  /// Clear the entire Actor cache
  static void clearCache() {
    _cache.clear();
    _primaryByUser.clear();
  }

  /// Add an actor to the cache, maintaining the primary-by-user index.
  static void _cacheActor(Actor actor) {
    _cache[actor.id] = actor;
    final userId = actor.linkedUserId;
    if (userId != null && actor.primary) {
      _primaryByUser[userId] = actor.id;
    }
  }

  /// Resolves [actorId] to the canonical actor id for its underlying person.
  ///
  /// Linked contacts (multiple email aliases for the same user) collapse to
  /// the user's current primary contact id. Twist instances and contacts
  /// not linked to any user pass through unchanged.
  ///
  /// Returns the input unchanged when:
  ///   - the actor is not in the cache,
  ///   - the actor has no [linkedUserId] (external contact / twist), or
  ///   - the user's primary actor isn't yet cached.
  ///
  /// The cache is populated lazily — call sites that depend on canonical
  /// resolution should ensure their target actors are loaded before
  /// rendering. In practice the actor sync (`Actor.pull` / `pullCritical`)
  /// covers self + thread-visible contacts up front.
  static ActorId canonicalId(ActorId actorId) {
    final actor = _cache[actorId];
    if (actor == null) return actorId;
    if (actor.primary) return actorId;
    final userId = actor.linkedUserId;
    if (userId == null) return actorId;
    return _primaryByUser[userId] ?? actorId;
  }

  /// Whether two actor ids represent the same underlying person/twist.
  /// Equivalent to `canonicalId(a) == canonicalId(b)`, but avoids two map
  /// lookups when the ids are already equal.
  static bool sameIdentity(ActorId a, ActorId b) {
    if (a == b) return true;
    return canonicalId(a) == canonicalId(b);
  }

  /// Deduplicate [ids] by canonical identity, preserving the first
  /// occurrence's order. Useful when reading raw `actor_id` arrays from
  /// the server (e.g. `note_tag.actor_ids` or `thread.contacts`) where
  /// linked-contact aliases may surface as multiple ids for one person.
  static List<ActorId> dedupeByIdentity(Iterable<ActorId> ids) {
    final seen = <ActorId>{};
    final out = <ActorId>[];
    for (final id in ids) {
      final canonical = canonicalId(id);
      if (seen.add(canonical)) out.add(canonical);
    }
    return out;
  }

  static Future<bool> push() async {
    return Store.get.push(table, ActorsBase());
  }

  static Future<void> pull() async {
    // First pull: fetch all actors if not already initialized
    await Store.get.pull(table, ActorsBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull
    await Store.get.pull(table, ActorsBase());
    // Repopulate cache with critical actors (self + twists)
    await pullCritical();
    // Rebuild the primary-by-user index from Drift so canonicalId() can
    // resolve any linked-alias actor synchronously without first having
    // to load the primary individually.
    await _rebuildPrimaryIndex();
  }

  /// Rebuilds [_primaryByUser] from the local Drift store. Cheap (one
  /// query, returns one row per linked user), but covers every linked
  /// contact the app has synced — so [canonicalId] never returns a stale
  /// alias id just because the primary hasn't been read into [_cache] yet.
  static Future<void> _rebuildPrimaryIndex() async {
    final a = Store.get.actors;
    final query = Store.get.select(a)
      ..where((row) => row.linkedUserId.isNotNull() & row.primary.equals(true));
    final rows = await query.get();
    _primaryByUser.clear();
    for (final row in rows) {
      final userId = row.linkedUserId;
      if (userId != null) _primaryByUser[userId] = row.id;
    }
  }

  /// Loads only critical actors into cache: self actors and priority twists.
  /// Other actors are cached lazily when accessed via get() or getOne().
  static Future<void> pullCritical() async {
    try {
      await Future(() async {
        // Query 1: Fetch only actors with self = true (user's own actors)
        // Typically 1-10 actors (user's email addresses across different contacts)
        await get(self: true, archived: null);

        // Query 2: Fetch only priority twist actors
        // Typically < 50 actors (one per active twist)
        await get(types: [ActorType.twistInstance], archived: null);

        // Both queries automatically populate the cache via get() (lines 84-87)
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      log.warning("Actor.pullCritical timed out after 10s — continuing with local data");
      Tracker.trackError(
        'auth',
        errorType: 'TimeoutException',
        errorMessage: 'Actor.pullCritical timed out after 10s',
        context: 'sign_in_actor_pull_timeout',
      );
    }
  }

  static Future<List<Actor>> get({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
    bool? inviteable,
    bool? primary,
  }) async {
    // Trigger archived sync if needed
    if (archived == true) {
      await Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      await Store.get.pullArchived(table, ActorsBase());
    }

    final actors = await _get(
      id: id,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
      self: self,
      inviteable: inviteable,
      primary: primary,
    ).get();

    // Cache all fetched actors for synchronous lookups
    for (final actor in actors) {
      _cacheActor(actor);
    }

    return actors;
  }

  static Stream<List<Actor>> watch({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
    bool? inviteable,
    bool? primary,
  }) {
    // Trigger archived sync if needed
    if (archived == true) {
      Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      Store.get.pullArchived(table, ActorsBase());
    }

    return _get(
      id: id,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
      self: self,
      inviteable: inviteable,
      primary: primary,
    ).watch();
  }

  /// Synchronous cache lookup. Returns null if the actor has not yet
  /// been fetched into the in-memory cache.
  static Actor? fromCache(ActorId id) => _cache[id];

  static Future<Actor> getOne(ActorId id) async {
    // Check cache first
    if (_cache.containsKey(id)) {
      return _cache[id]!;
    }

    // Cache miss - query database
    final actors = await _get(id: id, archived: null).get();
    if (actors.isEmpty) {
      throw Exception('Actor not found');
    }

    // Store in cache and return
    final actor = actors.first;
    _cacheActor(actor);
    return actor;
  }

  static Stream<Actor> watchOne(ActorId id) {
    return _get(id: id, archived: null).watch().map((actors) {
      if (actors.isEmpty) {
        throw Exception('Actor not found');
      }
      return actors.first;
    });
  }

  /// Returns non-self, non-archived user/contact actors ordered for thread
  /// sharing. Threads whose `topic` starts with `channel:` are
  /// connection-imported (calendar events, emails, etc.) and often pull in
  /// contacts the user never chose, so explicit-thread history takes
  /// precedence over connection-thread history at every band. Within
  /// explicit history, authored threads (where the user has actually
  /// sent a note) outrank received-only threads so inbound senders like
  /// `info@`, marketing, and newsletter accounts don't crowd out
  /// real correspondents:
  ///   1. Authored MRU — actors on the most-recent in-scope threads where
  ///      the user has authored at least one note, ordered by recency.
  ///   2. Authored frequent — remaining authored-thread actors, ordered
  ///      by authored-thread count (ties → alphabetical).
  ///   3. Explicit-only frequent — actors who appear only on
  ///      received-only explicit threads (e.g. unanswered newsletters),
  ///      ordered by explicit-thread count.
  ///   4. Channel-only frequent — actors with no in-scope explicit
  ///      history but who appear on in-scope channel threads, ordered by
  ///      count (ties → alphabetical). Channel threads never contribute
  ///      to MRU because they're auto-imported, not user-selected.
  ///   5. Rest — actors the user has no sharing history with in scope.
  ///      When [priority] is provided, this falls back to the user's
  ///      cross-priority MRU/frequent ordering before alphabetical.
  ///
  /// When [priority] is provided, thread scope is restricted to its subtree
  /// (priority + descendants). The candidate pool honors [search] via the
  /// same LIKE filter as [get].
  static Future<List<Actor>> getSortedForSharing({
    String? search,
    Priority? priority,
    int mruSize = 5,
    int threadWindow = 200,
  }) async {
    final candidates = await get(
      types: [ActorType.user, ActorType.contact],
      search: search,
      inviteable: true,
      primary: true,
    );

    final selfIds = getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    // `a.self` alone isn't enough: a contact synced before being linked to
    // the user can persist locally with self=false. Cross-check against
    // [getCurrentUserActorIds] (which always includes the primary contact)
    // so the user's own contacts never show up as sharing suggestions.
    candidates.removeWhere(
      (a) => a.self || selfIds.contains(a.id.toUuid()),
    );

    final scoped = await _scanThreadsForSharing(
      selfIds: selfIds,
      priorityPath: priority?.path,
      limit: threadWindow,
    );

    // Global scan is only needed as a tail fallback when a priority is
    // provided: actors with no in-priority history fall back to their
    // cross-priority MRU before the alphabetical tail.
    final global = priority == null
        ? scoped
        : await _scanThreadsForSharing(
            selfIds: selfIds,
            priorityPath: null,
            limit: threadWindow,
          );

    int byName(Actor a, Actor b) =>
        a.nameOrEmail.toLowerCase().compareTo(b.nameOrEmail.toLowerCase());

    final authoredSeen = <Actor>[];
    final explicitOnlySeen = <Actor>[];
    final channelOnlySeen = <Actor>[];
    final unseenInScope = <Actor>[];
    for (final actor in candidates) {
      final id = actor.id.toUuid();
      if (scoped.authoredFirstSeenIndex.containsKey(id)) {
        authoredSeen.add(actor);
      } else if (scoped.explicitFirstSeenIndex.containsKey(id)) {
        explicitOnlySeen.add(actor);
      } else if (scoped.firstSeenIndex.containsKey(id)) {
        channelOnlySeen.add(actor);
      } else {
        unseenInScope.add(actor);
      }
    }

    // MRU within authored threads: order by first-seen index (lower = more
    // recent). Tie-break alphabetically.
    authoredSeen.sort((a, b) {
      final ai = scoped.authoredFirstSeenIndex[a.id.toUuid()]!;
      final bi = scoped.authoredFirstSeenIndex[b.id.toUuid()]!;
      if (ai != bi) return ai.compareTo(bi);
      return byName(a, b);
    });

    final mru = authoredSeen.take(mruSize).toList();
    final frequent = authoredSeen.skip(mruSize).toList()
      ..sort((a, b) {
        final ca = scoped.authoredCounts[a.id.toUuid()] ?? 0;
        final cb = scoped.authoredCounts[b.id.toUuid()] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    // Explicit-only band: actors on explicit threads where the user has
    // NOT authored a note. Typical case: unanswered emails from
    // newsletters or `info@` addresses. No MRU here — recency of a
    // received-only thread doesn't reflect user intent. Sort by count,
    // ties alphabetical.
    final explicitFrequent = explicitOnlySeen
      ..sort((a, b) {
        final ca = scoped.explicitCounts[a.id.toUuid()] ?? 0;
        final cb = scoped.explicitCounts[b.id.toUuid()] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    // Channel-only band: actors only seen on connection-imported threads.
    // No MRU here — connector threads are auto-imported, so recency tells
    // us nothing about user intent. Sort by count, ties alphabetical.
    final channelFrequent = channelOnlySeen
      ..sort((a, b) {
        final ca = scoped.counts[a.id.toUuid()] ?? 0;
        final cb = scoped.counts[b.id.toUuid()] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    // Tail: for actors with no in-scope history, people the user has authored
    // to *anywhere* (global authored band) come first — otherwise a sparse or
    // empty priority surfaces only the recency tail, which inbound mailing
    // lists dominate. Then cross-priority recency, then alphabetical. When no
    // priority is provided, [global] === [scoped] so the authored/seen tails
    // are empty and this collapses to alphabetical.
    final tailAuthored = <Actor>[];
    final tailSeen = <Actor>[];
    final tailUnseen = <Actor>[];
    for (final actor in unseenInScope) {
      if (global.authoredFirstSeenIndex.containsKey(actor.id.toUuid())) {
        tailAuthored.add(actor);
      } else if (global.firstSeenIndex.containsKey(actor.id.toUuid())) {
        tailSeen.add(actor);
      } else {
        tailUnseen.add(actor);
      }
    }
    tailAuthored.sort((a, b) {
      final ca = global.authoredCounts[a.id.toUuid()] ?? 0;
      final cb = global.authoredCounts[b.id.toUuid()] ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      final ai = global.authoredFirstSeenIndex[a.id.toUuid()]!;
      final bi = global.authoredFirstSeenIndex[b.id.toUuid()]!;
      if (ai != bi) return ai.compareTo(bi);
      return byName(a, b);
    });
    tailSeen.sort((a, b) {
      final ai = global.firstSeenIndex[a.id.toUuid()]!;
      final bi = global.firstSeenIndex[b.id.toUuid()]!;
      if (ai != bi) return ai.compareTo(bi);
      final ca = global.counts[a.id.toUuid()] ?? 0;
      final cb = global.counts[b.id.toUuid()] ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return byName(a, b);
    });
    tailUnseen.sort(byName);

    return [
      ...mru,
      ...frequent,
      ...explicitFrequent,
      ...channelFrequent,
      ...tailAuthored,
      ...tailSeen,
      ...tailUnseen,
    ];
  }

  /// Single MRU-sorted list of share candidates — actors and groups
  /// interleaved by recency over the same thread scan as
  /// [getSortedForSharing]. The share modal renders this as one section so
  /// a freshly-used group sorts beside freshly-used contacts instead of
  /// pushing recent contacts down a separate "Groups" header.
  ///
  /// Banding mirrors [getSortedForSharing]: authored MRU, authored
  /// frequent, explicit-only frequent (received-only senders),
  /// channel-only frequent, then the tail (cross-priority MRU when
  /// [priority] is set, else alphabetical). Ties resolve alphabetically
  /// against [Actor.nameOrEmail] / [GroupRow.name].
  static Future<List<ShareCandidate>> getSortedShareCandidates({
    String? search,
    Priority? priority,
    int mruSize = 5,
    int threadWindow = 200,
    int searchLimit = 50,
    List<String> includeGroupIds = const [],
  }) async {
    final selfIds = getCurrentUserActorIds().map((a) => a.toUuid()).toSet();

    // Run thread scans first — drives MRU ranking, and in the empty-search
    // path also gates which candidates we materialize at all.
    final scoped = await _scanThreadsForSharing(
      selfIds: selfIds,
      priorityPath: priority?.path,
      limit: threadWindow,
    );
    final global = priority == null
        ? scoped
        : await _scanThreadsForSharing(
            selfIds: selfIds,
            priorityPath: null,
            limit: threadWindow,
          );

    // Candidate sourcing splits on whether the user is searching. With no
    // search we only materialize people who appear in the recent thread
    // window — alphabetically loading every inviteable contact on every
    // modal open is what made this slow for accounts with thousands of
    // contacts. Typing a few characters surfaces anyone outside that
    // window. Groups are always small ("a handful per user") so we keep
    // loading them in full.
    final List<Actor> actors;
    final List<GroupRow> groups;
    if (search == null || search.isEmpty) {
      // Materialize everyone surfaced by either scan. Authored contacts must
      // be included explicitly: their threads can sit outside the recent
      // window (the parent/root-priority case), so they may be absent from
      // [firstSeenIndex] yet belong at the top of the list.
      final actorIds = <Uuid>{
        ...scoped.authoredFirstSeenIndex.keys,
        ...scoped.firstSeenIndex.keys,
        ...global.authoredFirstSeenIndex.keys,
        ...global.firstSeenIndex.keys,
      };
      actors = await _getInviteablePrimaryByIds(
        actorIds.map(ActorId.fromUuid),
      );
      groups = await Group.getPostable(includeIds: includeGroupIds);
    } else {
      actors = await get(
        types: [ActorType.user, ActorType.contact],
        search: search,
        inviteable: true,
        primary: true,
        limit: searchLimit,
      );
      groups = await Group.getPostable(
        search: search,
        includeIds: includeGroupIds,
      );
    }
    actors.removeWhere(
      (a) => a.self || selfIds.contains(a.id.toUuid()),
    );

    String sortKey(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            actor.nameOrEmail.toLowerCase(),
          GroupShareCandidate(:final group) => group.name.toLowerCase(),
        };
    int byName(ShareCandidate a, ShareCandidate b) =>
        sortKey(a).compareTo(sortKey(b));

    int? authoredFirstSeen(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            scoped.authoredFirstSeenIndex[actor.id.toUuid()],
          GroupShareCandidate(:final group) =>
            scoped.groupAuthoredFirstSeenIndex[group.id],
        };
    int? explicitFirstSeen(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            scoped.explicitFirstSeenIndex[actor.id.toUuid()],
          GroupShareCandidate(:final group) =>
            scoped.groupExplicitFirstSeenIndex[group.id],
        };
    int? anyFirstSeen(ShareCandidate c, ThreadScanResult scan) =>
        switch (c) {
          ActorShareCandidate(:final actor) =>
            scan.firstSeenIndex[actor.id.toUuid()],
          GroupShareCandidate(:final group) =>
            scan.groupFirstSeenIndex[group.id],
        };
    int authoredCount(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            scoped.authoredCounts[actor.id.toUuid()] ?? 0,
          GroupShareCandidate(:final group) =>
            scoped.groupAuthoredCounts[group.id] ?? 0,
        };
    int explicitCount(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            scoped.explicitCounts[actor.id.toUuid()] ?? 0,
          GroupShareCandidate(:final group) =>
            scoped.groupExplicitCounts[group.id] ?? 0,
        };
    int anyCount(ShareCandidate c, ThreadScanResult scan) => switch (c) {
          ActorShareCandidate(:final actor) =>
            scan.counts[actor.id.toUuid()] ?? 0,
          GroupShareCandidate(:final group) =>
            scan.groupCounts[group.id] ?? 0,
        };

    final candidates = <ShareCandidate>[
      ...actors.map(ActorShareCandidate.new),
      ...groups.map(GroupShareCandidate.new),
    ];

    final authoredSeen = <ShareCandidate>[];
    final explicitOnlySeen = <ShareCandidate>[];
    final channelOnlySeen = <ShareCandidate>[];
    final unseen = <ShareCandidate>[];
    for (final c in candidates) {
      if (authoredFirstSeen(c) != null) {
        authoredSeen.add(c);
      } else if (explicitFirstSeen(c) != null) {
        explicitOnlySeen.add(c);
      } else if (anyFirstSeen(c, scoped) != null) {
        channelOnlySeen.add(c);
      } else {
        unseen.add(c);
      }
    }

    authoredSeen.sort((a, b) {
      final ai = authoredFirstSeen(a)!;
      final bi = authoredFirstSeen(b)!;
      if (ai != bi) return ai.compareTo(bi);
      return byName(a, b);
    });

    final mru = authoredSeen.take(mruSize).toList();
    final frequent = authoredSeen.skip(mruSize).toList()
      ..sort((a, b) {
        final ca = authoredCount(a);
        final cb = authoredCount(b);
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    // Explicit-only: actors/groups on explicit threads where the user
    // never authored a note. Received-only newsletters / `info@` land
    // here. No MRU — received recency isn't a user-intent signal.
    final explicitFrequent = explicitOnlySeen
      ..sort((a, b) {
        final ca = explicitCount(a);
        final cb = explicitCount(b);
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    final channelFrequent = channelOnlySeen
      ..sort((a, b) {
        final ca = anyCount(a, scoped);
        final cb = anyCount(b, scoped);
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });

    // Tail: candidates with no history in the scoped priority. People the
    // user has authored to *anywhere* (global authored band) come first —
    // otherwise a thread filed under a sparse/empty priority would surface
    // only the recency tail, which is dominated by inbound mailing lists.
    // Then global recency-seen, then alphabetical.
    int? globalAuthoredFirstSeen(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            global.authoredFirstSeenIndex[actor.id.toUuid()],
          GroupShareCandidate(:final group) =>
            global.groupAuthoredFirstSeenIndex[group.id],
        };
    int globalAuthoredCount(ShareCandidate c) => switch (c) {
          ActorShareCandidate(:final actor) =>
            global.authoredCounts[actor.id.toUuid()] ?? 0,
          GroupShareCandidate(:final group) =>
            global.groupAuthoredCounts[group.id] ?? 0,
        };

    final tailAuthored = <ShareCandidate>[];
    final tailSeen = <ShareCandidate>[];
    final tailUnseen = <ShareCandidate>[];
    for (final c in unseen) {
      if (globalAuthoredFirstSeen(c) != null) {
        tailAuthored.add(c);
      } else if (anyFirstSeen(c, global) != null) {
        tailSeen.add(c);
      } else {
        tailUnseen.add(c);
      }
    }
    tailAuthored.sort((a, b) {
      final ca = globalAuthoredCount(a);
      final cb = globalAuthoredCount(b);
      if (ca != cb) return cb.compareTo(ca);
      final ai = globalAuthoredFirstSeen(a)!;
      final bi = globalAuthoredFirstSeen(b)!;
      if (ai != bi) return ai.compareTo(bi);
      return byName(a, b);
    });
    tailSeen.sort((a, b) {
      final ai = anyFirstSeen(a, global)!;
      final bi = anyFirstSeen(b, global)!;
      if (ai != bi) return ai.compareTo(bi);
      final ca = anyCount(a, global);
      final cb = anyCount(b, global);
      if (ca != cb) return cb.compareTo(ca);
      return byName(a, b);
    });
    tailUnseen.sort(byName);

    return [
      ...mru,
      ...frequent,
      ...explicitFrequent,
      ...channelFrequent,
      ...tailAuthored,
      ...tailSeen,
      ...tailUnseen,
    ];
  }

  static Future<ThreadScanResult> _scanThreadsForSharing({
    required Set<Uuid> selfIds,
    required Path? priorityPath,
    required int limit,
  }) async {
    // Two independent thread sources:
    //   - `recent`: the most-recent N threads in scope (the activity feed).
    //     Drives the explicit-only / channel / cross-priority fallback bands.
    //   - `authored`: the most-recent N threads in scope that the user has
    //     written a note in. Drives the top "Authored" bands.
    // These are scanned separately because in an aggregating parent/root
    // priority the recent window is a tiny, recency-biased slice of thousands
    // of threads, so the user's authored relationships fall outside it. Pulling
    // authored threads directly keeps the authored band populated regardless of
    // how much inbound noise (newsletters, mailing lists) sits above them in the
    // feed.
    final recent = await Thread.get(
      priorityPath: priorityPath,
      draft: false,
      archived: false,
      order: ThreadOrder.reverse,
      limit: limit,
    );
    final authored = await authoredThreadsForSharing(
      selfIds: selfIds,
      priorityPath: priorityPath,
      limit: limit,
    );
    return buildShareScan(
      recent: recent
          .map(
            (t) => ShareScanThread(
              id: t.id,
              contacts: t.contacts,
              groups: t.groups,
              isExplicit: !(t.topic?.startsWith('channel:') ?? false),
            ),
          )
          .toList(),
      authored: authored,
      selfIds: selfIds,
    );
  }

  /// Builds the share-picker tallies from two ordered thread lists.
  ///
  /// [recent] (most-recent-first) populates the explicit-only / channel /
  /// cross-priority bands. [authored] (most-recent-first) populates the top
  /// "Authored" bands. The two use independent index spaces — each band only
  /// ever compares first-seen indices within itself, so the authored MRU stays
  /// correct while being sourced from a different query than the recent feed.
  ///
  /// Pure and side-effect free so it can be unit-tested without a database.
  @visibleForTesting
  static ThreadScanResult buildShareScan({
    required List<ShareScanThread> recent,
    required List<ShareScanThread> authored,
    required Set<Uuid> selfIds,
  }) {
    final firstSeenIndex = <Uuid, int>{};
    final counts = <Uuid, int>{};
    final explicitFirstSeenIndex = <Uuid, int>{};
    final explicitCounts = <Uuid, int>{};
    final authoredFirstSeenIndex = <Uuid, int>{};
    final authoredCounts = <Uuid, int>{};
    final groupFirstSeenIndex = <Uuid, int>{};
    final groupCounts = <Uuid, int>{};
    final groupExplicitFirstSeenIndex = <Uuid, int>{};
    final groupExplicitCounts = <Uuid, int>{};
    final groupAuthoredFirstSeenIndex = <Uuid, int>{};
    final groupAuthoredCounts = <Uuid, int>{};

    // Recent window: explicit-only / channel / cross-priority bands.
    for (var i = 0; i < recent.length; i++) {
      final thread = recent[i];
      for (final contactId in thread.contacts) {
        if (selfIds.contains(contactId)) continue;
        firstSeenIndex.putIfAbsent(contactId, () => i);
        counts[contactId] = (counts[contactId] ?? 0) + 1;
        if (thread.isExplicit) {
          explicitFirstSeenIndex.putIfAbsent(contactId, () => i);
          explicitCounts[contactId] = (explicitCounts[contactId] ?? 0) + 1;
        }
      }
      for (final groupId in thread.groups) {
        groupFirstSeenIndex.putIfAbsent(groupId, () => i);
        groupCounts[groupId] = (groupCounts[groupId] ?? 0) + 1;
        if (thread.isExplicit) {
          groupExplicitFirstSeenIndex.putIfAbsent(groupId, () => i);
          groupExplicitCounts[groupId] =
              (groupExplicitCounts[groupId] ?? 0) + 1;
        }
      }
    }

    // Authored threads: the top "Authored" bands. Sourced independently of the
    // recent window so people the user writes to surface even when their
    // threads are older than the recent activity feed.
    for (var i = 0; i < authored.length; i++) {
      final thread = authored[i];
      for (final contactId in thread.contacts) {
        if (selfIds.contains(contactId)) continue;
        authoredFirstSeenIndex.putIfAbsent(contactId, () => i);
        authoredCounts[contactId] = (authoredCounts[contactId] ?? 0) + 1;
      }
      for (final groupId in thread.groups) {
        groupAuthoredFirstSeenIndex.putIfAbsent(groupId, () => i);
        groupAuthoredCounts[groupId] = (groupAuthoredCounts[groupId] ?? 0) + 1;
      }
    }

    return ThreadScanResult(
      firstSeenIndex: firstSeenIndex,
      counts: counts,
      explicitFirstSeenIndex: explicitFirstSeenIndex,
      explicitCounts: explicitCounts,
      authoredFirstSeenIndex: authoredFirstSeenIndex,
      authoredCounts: authoredCounts,
      groupFirstSeenIndex: groupFirstSeenIndex,
      groupCounts: groupCounts,
      groupExplicitFirstSeenIndex: groupExplicitFirstSeenIndex,
      groupExplicitCounts: groupExplicitCounts,
      groupAuthoredFirstSeenIndex: groupAuthoredFirstSeenIndex,
      groupAuthoredCounts: groupAuthoredCounts,
    );
  }

  /// Fetches the most-recent [limit] threads in scope that contain at least
  /// one note authored by one of [selfIds], newest first. Scoped to the
  /// priority subtree (priority + descendants) when [priorityPath] is set.
  ///
  /// This is the authored-band source. Unlike the recent activity feed, it is
  /// not crowded out by inbound mail, so the people the user actually writes to
  /// surface even in an aggregating parent/root priority. Recency uses the
  /// last-note / bump / creation timestamp as a proxy for the feed's computed
  /// `activity_at`; exact ordering only affects the small top-N MRU slice, the
  /// frequency bands below it are order-independent.
  @visibleForTesting
  static Future<List<ShareScanThread>> authoredThreadsForSharing({
    required Set<Uuid> selfIds,
    required Path? priorityPath,
    required int limit,
  }) async {
    if (selfIds.isEmpty) return const [];
    final a = Store.get.threads;
    final n = Store.get.alias(Store.get.notes, 'authored_note');
    final selfBytes = selfIds.map((id) => id.toBytes()).toList();

    final joins = <Join<HasResultSet, dynamic>>[];
    if (priorityPath != null) {
      final p = Store.get.alias(Store.get.priorities, 'authored_priority');
      joins.add(
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
      );
    }

    final query = Store.get.select(a).join(joins)
      ..where(
        a.archivedAt.isNull() &
            a.draft.equals(false) &
            existsQuery(
              Store.get.selectOnly(n)
                ..addColumns([n.id])
                ..where(
                  n.threadId.equalsExp(a.id) & n.authorId.isIn(selfBytes),
                ),
            ),
      )
      ..orderBy([
        OrderingTerm.desc(a.lastNoteCreatedAt),
        OrderingTerm.desc(a.bumpedAt),
        OrderingTerm.desc(a.createdAt),
      ])
      ..limit(limit);

    final rows = await query.get();
    return rows.map((row) {
      final t = row.readTable(a);
      return ShareScanThread(
        id: t.id,
        contacts: t.contacts ?? const [],
        groups: t.groups ?? const [],
        isExplicit: !(t.topic?.startsWith('channel:') ?? false),
      );
    }).toList();
  }

  /// Returns all actor IDs that belong to the current user.
  /// Uses the Actor cache for synchronous lookup, and always unions in
  /// [Base.actorIdOrNull] so the user's primary contact is included even when
  /// the local actor row is stale (e.g. synced before the contact was linked
  /// to the user) or the cache hasn't been populated yet.
  static List<ActorId> getCurrentUserActorIds() {
    final ids = <ActorId>{};
    for (final actor in _cache.values) {
      if (actor.self) ids.add(actor.id);
    }
    final basePrimary =
        Injector.appInstance.exists<Base>() ? Base.actorIdOrNull : null;
    if (basePrimary != null) ids.add(basePrimary);
    return ids.toList();
  }

  /// Get Actor by auth user ID (via contact.user_id lookup).
  /// Returns null if no contact is found for the given user ID.
  // TODO: Add API endpoint to look up contact by user_id, or sync user_id to local actors table
  static Future<Actor?> getByUserId(Uuid userId) async {
    try {
      final result = await api.get<List<dynamic>>(
        '/contact/by-user/${userId.toString()}',
      );
      if (result.isEmpty) return null;

      final contactId = result.first['id'] as String;
      final actorId = ActorId.fromString(contactId);

      return await getOne(actorId);
    } catch (e) {
      return null;
    }
  }

  /// Returns canonical UUID strings of non-archived user/contact actors
  /// whose name has a word starting with [word] (anchored at the start of
  /// any space-separated name part), or whose email starts with [word].
  /// Matching is case-insensitive for ASCII via SQLite's default LIKE
  /// behavior. Returns an empty list when [word] is empty.
  ///
  /// Includes non-primary alias contacts because `thread.contacts` may
  /// reference an alias ID rather than the user's primary contact —
  /// dropping aliases here would silently miss threads the user can see.
  ///
  /// Used by thread search to surface threads shared with a contact whose
  /// name matches the typed query.
  static Future<List<String>> idsMatchingWordPrefix(String word) async {
    if (word.isEmpty) return const [];
    final lower = word.toLowerCase();
    final a = Store.get.actors;
    final query = Store.get.select(a)
      ..where(
        (row) =>
            row.archivedAt.isNull() &
            row.type.isIn(
              ActorType.values
                  .where(
                    (t) => t == ActorType.user || t == ActorType.contact,
                  )
                  .map((t) => t.name.toSnakeCase())
                  .toList(),
            ) &
            (row.name.like('$lower%') |
                row.name.like('% $lower%') |
                row.email.like('$lower%')),
      );
    final rows = await query.get();
    return rows.map((r) => r.id.toUuid().toString()).toList();
  }

  /// Fetches user/contact actors by id and applies the share-picker's
  /// standard non-archived / inviteable / primary filters in one query.
  /// Used by [getSortedShareCandidates] to materialize only the candidates
  /// surfaced by the recent-threads scan.
  static Future<List<Actor>> _getInviteablePrimaryByIds(
    Iterable<ActorId> ids,
  ) async {
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) return [];
    final a = Store.get.actors;
    final typeStrings = [ActorType.user, ActorType.contact]
        .map((t) => t.name.toSnakeCase())
        .toList();
    final query = Store.get.select(a)
      ..where(
        (row) =>
            row.id.isIn(idList.map((id) => id.toBytes()).toList()) &
            row.archivedAt.isNull() &
            row.type.isIn(typeStrings) &
            row.inviteable.equals(true) &
            row.primary.equals(true) &
            (row.name.isNotNull() | row.email.isNotNull()),
      );
    final rows = await query.get();
    final actors = rows.map(Actor.fromStore).toList();
    for (final actor in actors) {
      _cacheActor(actor);
    }
    return actors;
  }

  static MultiSelectable<Actor> _get({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
    bool? inviteable,
    bool? primary,
  }) {
    final a = Store.get.actors;
    final query = Store.get.select(a).join([]);

    // Apply archived filter
    if (archived == true) {
      query.where(a.archivedAt.isNotNull());
    } else if (archived == false) {
      query.where(a.archivedAt.isNull());
    }
    // archived == null means no filter (include all)

    // Exclude contacts with no name and no email (they'd show as "Unknown")
    // Skip this filter when querying by specific ID (e.g. resolving note authors)
    if (id == null) {
      query.where(
        a.name.isNotNull() | a.email.isNotNull(),
      );
    }

    // Filter by ID
    if (id != null) {
      query.where(a.id.equalsValue(id));
    }

    // Filter by actor types
    if (types != null && types.isNotEmpty) {
      final typeStrings = types
          .map((t) => (t as Enum).name.toSnakeCase())
          .toList();
      query.where(a.type.isIn(typeStrings));
    }

    // Filter by self flag
    if (self != null) {
      query.where(a.self.equals(self));
    }

    // Filter by inviteable (default: no filter; callers opt in by passing true)
    if (inviteable != null) {
      query.where(a.inviteable.equals(inviteable));
    }

    // Filter by primary (default: no filter; pickers opt in by passing true
    // to hide non-primary linked contacts — the alternate-email aliases kept
    // for historical author resolution).
    if (primary != null) {
      query.where(a.primary.equals(primary));
    }

    // Search by name or email (case-insensitive with LIKE)
    if (search != null && search.isNotEmpty) {
      final searchPattern = '%${search.toLowerCase()}%';
      query.where(a.name.like(searchPattern) | a.email.like(searchPattern));
    }

    // Apply limit
    if (limit != null) {
      query.limit(limit);
    }

    // Map results, reading from the joined query
    return query.map((row) => Actor.fromStore(row.readTable(a)));
  }

  Actor.fromStore(ActorRow row)
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        type: row.type,
        name: row.name,
        email: row.email,
        avatarUrl: row.avatarUrl,
        self: row.self,
        inviteable: row.inviteable,
        primary: row.primary,
        linkedUserId: row.linkedUserId,
        externalAccounts: row.externalAccounts,
      );

  @override
  Actor copyWith({
    ActorId? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    ActorType? type,
    Value<String?> name = const Value.absent(),
    Value<String?> email = const Value.absent(),
    Value<String?> avatarUrl = const Value.absent(),
    bool? self,
    bool? inviteable,
    bool? primary,
    Value<Uuid?> linkedUserId = const Value.absent(),
    Value<int?> pending = const Value.absent(),
    List<ContactExternalAccount>? externalAccounts,
  }) => Actor.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      archivedAt: archivedAt,
      type: type,
      name: name,
      email: email,
      avatarUrl: avatarUrl,
      self: self,
      inviteable: inviteable,
      primary: primary,
      linkedUserId: linkedUserId,
      pending: pending,
      externalAccounts: externalAccounts,
    ),
  );

  /// Returns the actor's name if available, otherwise their email
  String get nameOrEmail {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    return email ?? 'Unknown';
  }

  /// Returns true if this actor has at least one external account for the
  /// given connection ([twistInstanceId]). Used by the DM picker to filter
  /// contacts reachable via a specific connection (e.g. one Slack workspace).
  bool hasExternalAccount(Uuid twistInstanceId) {
    return externalAccounts.any((a) => a.twistInstanceId == twistInstanceId);
  }

  /// Returns all external accounts for the given connection
  /// ([twistInstanceId]), or all accounts if [twistInstanceId] is null.
  List<ContactExternalAccount> externalAccountsFor([Uuid? twistInstanceId]) {
    if (twistInstanceId == null) return externalAccounts;
    return externalAccounts
        .where((a) => a.twistInstanceId == twistInstanceId)
        .toList();
  }
}

/// Either an [Actor] or a [GroupRow], surfaced together by
/// [Actor.getSortedShareCandidates] so the share picker can render
/// people and groups in a single MRU-ordered list.
sealed class ShareCandidate {
  const ShareCandidate();
}

class ActorShareCandidate extends ShareCandidate {
  const ActorShareCandidate(this.actor);
  final Actor actor;
}

class GroupShareCandidate extends ShareCandidate {
  const GroupShareCandidate(this.group);
  final GroupRow group;
}

/// Minimal thread shape consumed by [Actor.buildShareScan]: the contact and
/// group ids on a thread plus whether it is an explicit (non-channel) thread.
/// Kept independent of [Thread] so the ranking is unit-testable without a DB.
class ShareScanThread {
  const ShareScanThread({
    required this.id,
    required this.contacts,
    required this.groups,
    this.isExplicit = true,
  });

  final Uuid id;
  final List<Uuid> contacts;
  final List<Uuid> groups;

  /// True when the thread is not connection-imported (`topic` does not start
  /// with `channel:`). Only meaningful for the recent-window source.
  final bool isExplicit;
}

class ThreadScanResult {
  ThreadScanResult({
    required this.firstSeenIndex,
    required this.counts,
    required this.explicitFirstSeenIndex,
    required this.explicitCounts,
    required this.authoredFirstSeenIndex,
    required this.authoredCounts,
    required this.groupFirstSeenIndex,
    required this.groupCounts,
    required this.groupExplicitFirstSeenIndex,
    required this.groupExplicitCounts,
    required this.groupAuthoredFirstSeenIndex,
    required this.groupAuthoredCounts,
  });

  /// First-seen index and counts across all scanned threads.
  final Map<Uuid, int> firstSeenIndex;
  final Map<Uuid, int> counts;

  /// Same, but restricted to threads the user explicitly created — i.e.
  /// `topic` does not start with `channel:`. Connection-imported threads
  /// (calendar events, emails, etc.) often pull in contacts the user
  /// never chose, so we use this to prioritize contacts from threads the
  /// user actually started.
  final Map<Uuid, int> explicitFirstSeenIndex;
  final Map<Uuid, int> explicitCounts;

  /// Same as [explicitFirstSeenIndex]/[explicitCounts] but restricted to
  /// threads where the user has authored at least one note (sent a
  /// message). Drives the top "Authored" bands so the picker prioritizes
  /// people the user has actually written to over senders the user only
  /// receives from (newsletters, info@, marketing).
  final Map<Uuid, int> authoredFirstSeenIndex;
  final Map<Uuid, int> authoredCounts;

  /// Group MRU/frequency tallies, keyed on `thread.groups`. Groups share
  /// the same thread index space as actors so the merged share picker
  /// can interleave them by recency.
  final Map<Uuid, int> groupFirstSeenIndex;
  final Map<Uuid, int> groupCounts;
  final Map<Uuid, int> groupExplicitFirstSeenIndex;
  final Map<Uuid, int> groupExplicitCounts;
  final Map<Uuid, int> groupAuthoredFirstSeenIndex;
  final Map<Uuid, int> groupAuthoredCounts;
}

/// Drift converter for ActorId
class ActorIdConverter extends TypeConverter<ActorId, Uint8List>
    with JsonTypeConverter2<ActorId, Uint8List, String> {
  const ActorIdConverter();

  @override
  ActorId fromSql(Uint8List fromDb) {
    return ActorId.fromUuid(Uuid.fromBytes(fromDb));
  }

  @override
  Uint8List toSql(ActorId value) {
    return value.toUuid().toBytes();
  }

  @override
  ActorId fromJson(String json) {
    return ActorId.fromString(json);
  }

  @override
  String toJson(ActorId value) {
    return value.toString();
  }
}

/// Drift converter for lists of ActorIds
class ActorIdListConverter extends TypeConverter<List<ActorId>, String>
    with JsonTypeConverter2<List<ActorId>, String, List<dynamic>> {
  const ActorIdListConverter();

  @override
  List<ActorId> fromSql(String fromDb) {
    if (fromDb.isEmpty) return [];
    return fromDb
        .split(',')
        .map((uuidStr) => ActorId.fromString(uuidStr.trim()))
        .toList();
  }

  @override
  String toSql(List<ActorId> value) {
    return value.map((id) => id.toString()).join(',');
  }

  @override
  List<ActorId> fromJson(List<dynamic> json) {
    return json.map((item) => ActorId.fromString(item as String)).toList();
  }

  @override
  List<dynamic> toJson(List<ActorId> value) {
    return value.map((id) => id.toString()).toList();
  }
}

/// Extension methods for ActorId to check if it belongs to the current user
extension ActorIdHelpers on ActorId {
  /// Synchronous version - checks if this ActorId belongs to the current user.
  /// Only use when Actor data is guaranteed to be cached (after startup sync).
  /// Falls back to checking against the primary contact if Actor not cached.
  bool get isCurrentUser {
    final actor = Actor._cache[this];
    if (actor == null) {
      // Fallback to primary contact check if not in cache
      return this == Base.actorId;
    }
    return actor.self;
  }

  /// Check if this actor is a twist (twistInstance type).
  /// Uses TwistInstance cache for synchronous lookup - returns false if not cached.
  /// Note: TwistInstance.id IS the ActorId for twists.
  bool get isTwist {
    // Convert ActorId to Uuid since TwistInstance._cache uses TwistInstanceId (Uuid)
    final twistId = toUuid();
    return TwistInstance._cache.containsKey(twistId);
  }
}
