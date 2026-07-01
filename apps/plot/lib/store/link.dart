part of 'store.dart';

typedef LinkId = Uuid;

/// How sharing on threads of this link type is scoped. Mirrors
/// `LinkTypeConfig.sharingModel` in
/// `public/twister/src/tools/integrations.ts`.
enum SharingModel {
  /// One roster shared across all notes (default). Native threads,
  /// Slack DMs, calendar events.
  thread,
  /// Visibility is the external channel's membership; per-thread
  /// contacts are ignored for sharing UI. Slack channels, Linear.
  channel,
  /// Each note carries its own recipient set via access_contacts;
  /// thread roster is the union across messages. Email.
  message,
  /// No recipient roster and no sharing UI. Threads scoped this way never
  /// surface contacts/groups for sharing — treated like a [thread] with an
  /// empty roster. Used by link types that have no audience concept.
  none;

  static SharingModel fromJson(String? value) => switch (value) {
        'channel' => SharingModel.channel,
        'message' => SharingModel.message,
        'none' => SharingModel.none,
        _ => SharingModel.thread,
      };
}

/// Describes a link type that a source creates.
class LinkTypeConfig {
  final String type;
  final String label;
  /// Product/source name for this link type, used in place of the connector's
  /// display name when building "{source} {type}" copy (the thread type name,
  /// "Create new …" picker, compose chips). Only aggregate connectors that
  /// bundle several products under one display name set it — the Google
  /// connector's display name is "Gmail & Calendar", but its `event` link type
  /// carries `sourceName: "Google Calendar"`, `email` → "Gmail", `task` →
  /// "Google Tasks". Null falls back to the connector/twist display name.
  final String? sourceName;
  /// Connector's word for a note on a linked item of this type (e.g. "Comment"
  /// on Linear, "Message" on Slack, "Reply" on Gmail). Drives adaptive
  /// composer hints and command titles. Null falls back to "note".
  final String? noteLabel;
  final String? logo;
  final String? logoDark;
  final String? logoMono;
  final List<LinkStatus>? statuses;
  final bool supportsAssignee;
  /// Whether this link type produces time-anchored schedule/agenda items
  /// (calendar events). Drives whether the app surfaces the agenda. Mirrors
  /// `LinkTypeConfig.includesSchedules` in twister. Defaults to false.
  final bool includesSchedules;
  /// Opt-in: declares this link type is composable from Plot via
  /// `Connector.onCreateLink`. Null = sync-only (no Create entry).
  final ComposeConfig? compose;
  /// Per-connector contact roles for this link type. Email connectors declare
  /// To/CC/BCC, calendar connectors declare Required/Optional, etc. Empty or
  /// null when the connector does not distinguish roles (Slack, Linear).
  final List<ContactRoleConfig>? contactRoles;
  /// Whether contacts on an existing thread can be added/removed or have their
  /// role changed. Email-style threads set this true; messaging connectors
  /// where the recipient list is fixed at creation set it false.
  final bool supportsContactChanges;
  /// Whether a note/reply on this link type can carry a link (pasted URL or
  /// connector-created item) that Plot forwards to the source. False (default)
  /// hides the "Add link" button for threads of this link type. Private Plot
  /// notes (no link type) always allow links.
  final bool supportsLinks;
  /// Whether a note/reply on this link type can carry an uploaded file that
  /// Plot forwards to the source. False (default) hides the "Attach file"
  /// button for threads of this link type. Private Plot notes always allow
  /// attachments.
  final bool supportsFileAttachments;
  /// How sharing on threads of this link type is scoped. See
  /// [SharingModel]. Defaults to thread.
  final SharingModel sharingModel;
  /// Placeholder text for the compose (new message) input field. Null falls
  /// back to a generic default.
  final String? composePlaceholder;
  /// Verb shown on the compose submit button (e.g. "Send"). Null falls back
  /// to a generic default.
  final String? composeVerb;
  /// Placeholder text for the reply input field. Null falls back to a generic
  /// default.
  final String? replyPlaceholder;
  /// Verb shown on the reply submit button (e.g. "Send"). Null falls back to
  /// a generic default.
  final String? replyVerb;
  /// Reaction capabilities declared for this link type (e.g. the LinkedIn
  /// post reaction set), overriding the connector-level
  /// `TwistInstance.reactionCapabilities` when present. Null falls back to
  /// the connector-level value. See `Channel.reactionCapabilitiesFor`.
  final Map<String, dynamic>? reactionCapabilities;

  const LinkTypeConfig({
    required this.type,
    required this.label,
    this.sourceName,
    this.noteLabel,
    this.logo,
    this.logoDark,
    this.logoMono,
    this.statuses,
    this.supportsAssignee = false,
    this.includesSchedules = false,
    this.compose,
    this.contactRoles,
    this.supportsContactChanges = false,
    this.supportsLinks = false,
    this.supportsFileAttachments = false,
    this.sharingModel = SharingModel.thread,
    this.composePlaceholder,
    this.composeVerb,
    this.replyPlaceholder,
    this.replyVerb,
    this.reactionCapabilities,
  });

  factory LinkTypeConfig.fromJson(Map<String, dynamic> json) {
    return LinkTypeConfig(
      type: json['type'] as String,
      label: json['label'] as String,
      sourceName:
          json['sourceName'] as String? ?? json['source_name'] as String?,
      noteLabel:
          json['noteLabel'] as String? ?? json['note_label'] as String?,
      logo: json['logo'] as String?,
      logoDark: json['logoDark'] as String? ?? json['logo_dark'] as String?,
      logoMono: json['logoMono'] as String? ?? json['logo_mono'] as String?,
      statuses: (json['statuses'] as List<dynamic>?)
          ?.map((s) => LinkStatus.fromJson(s as Map<String, dynamic>))
          .toList(),
      supportsAssignee:
          json['supportsAssignee'] as bool? ??
          json['supports_assignee'] as bool? ??
          false,
      includesSchedules:
          json['includesSchedules'] as bool? ??
          json['includes_schedules'] as bool? ??
          false,
      compose: ComposeConfig.fromJson(json),
      contactRoles: (json['contactRoles'] as List<dynamic>? ??
              json['contact_roles'] as List<dynamic>?)
          ?.map((r) => ContactRoleConfig.fromJson(r as Map<String, dynamic>))
          .toList(),
      supportsContactChanges:
          json['supportsContactChanges'] as bool? ??
              json['supports_contact_changes'] as bool? ??
              false,
      supportsLinks:
          json['supportsLinks'] as bool? ??
          json['supports_links'] as bool? ??
          false,
      supportsFileAttachments:
          json['supportsFileAttachments'] as bool? ??
          json['supports_file_attachments'] as bool? ??
          false,
      sharingModel: SharingModel.fromJson(
        json['sharingModel'] as String? ?? json['sharing_model'] as String?,
      ),
      composePlaceholder: json['composePlaceholder'] as String? ??
          json['compose_placeholder'] as String?,
      composeVerb:
          json['composeVerb'] as String? ?? json['compose_verb'] as String?,
      replyPlaceholder: json['replyPlaceholder'] as String? ??
          json['reply_placeholder'] as String?,
      replyVerb:
          json['replyVerb'] as String? ?? json['reply_verb'] as String?,
      reactionCapabilities:
          json['reactionCapabilities'] as Map<String, dynamic>? ??
          json['reaction_capabilities'] as Map<String, dynamic>?,
    );
  }

  /// The default role for newly-added contacts, or null when no roles are
  /// declared. Returns the explicit `default: true` role when present,
  /// otherwise the first role in the list.
  ContactRoleConfig? get defaultContactRole {
    final roles = contactRoles;
    if (roles == null || roles.isEmpty) return null;
    return roles.firstWhere(
      (r) => r.isDefault,
      orElse: () => roles.first,
    );
  }
}

/// One role a connector defines for contacts on a thread. See
/// [LinkTypeConfig.contactRoles].
class ContactRoleConfig extends Equatable {
  /// Machine id, e.g. "to" / "cc" / "bcc" / "required" / "optional".
  final String id;
  /// Display label shown next to the contact chip.
  final String label;
  /// Whether this is the default role for newly-added contacts. Exactly one
  /// role per link type should set this; if none do, the first role in
  /// `contactRoles` is treated as default.
  final bool isDefault;
  /// Hidden roles (BCC-style) are visible only to the contact themselves and
  /// the user who added them. The Flutter UI uses this to warn the user when
  /// picking a hidden role; the server enforces actual filtering.
  final bool hidden;

  const ContactRoleConfig({
    required this.id,
    required this.label,
    this.isDefault = false,
    this.hidden = false,
  });

  factory ContactRoleConfig.fromJson(Map<String, dynamic> json) {
    return ContactRoleConfig(
      id: json['id'] as String,
      label: json['label'] as String,
      isDefault: json['default'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [id, label, isDefault, hidden];
}

/// Curated status-icon vocabulary. Mirrors `StatusIcon` in
/// `public/twister/src/tools/integrations.ts`. Connectors map each status to
/// one of these; the client renders a single glyph per value.
enum StatusIcon {
  backlog,
  todo,
  inProgress,
  blocked,
  done,
  cancelled,
  confirmed,
  tentative;

  /// Parse the SDK string form, or null for absent/unknown values (so an
  /// older cached config or a future icon never crashes the client).
  static StatusIcon? fromJson(String? value) => switch (value) {
        'backlog' => StatusIcon.backlog,
        'todo' => StatusIcon.todo,
        'inProgress' => StatusIcon.inProgress,
        'blocked' => StatusIcon.blocked,
        'done' => StatusIcon.done,
        'cancelled' => StatusIcon.cancelled,
        'confirmed' => StatusIcon.confirmed,
        'tentative' => StatusIcon.tentative,
        _ => null,
      };

  /// The glyph rendered for this status. Total over all values so the UI
  /// always has something to show (the SDK marks `icon` required).
  IconData get glyph => switch (this) {
        StatusIcon.backlog => FontAwesomeIcons.circleDashed,
        StatusIcon.todo => FontAwesomeIcons.circle,
        StatusIcon.inProgress => FontAwesomeIcons.circleHalfStroke,
        StatusIcon.blocked => FontAwesomeIcons.octagonXmark,
        StatusIcon.done => FontAwesomeIcons.circleCheck,
        StatusIcon.cancelled => FontAwesomeIcons.circleXmark,
        StatusIcon.confirmed => FontAwesomeIcons.calendarCheck,
        StatusIcon.tentative => FontAwesomeIcons.circleQuestion,
      };
}

/// A possible status value within a LinkTypeConfig.
class LinkStatus {
  final String status;
  final String label;
  final int? tag;
  final StatusIcon? icon;
  final bool hiddenDefault;
  final bool done;
  final bool todo;

  const LinkStatus({
    required this.status,
    required this.label,
    this.tag,
    this.icon,
    this.hiddenDefault = false,
    this.done = false,
    this.todo = false,
  });

  factory LinkStatus.fromJson(Map<String, dynamic> json) {
    return LinkStatus(
      status: json['status'] as String,
      label: json['label'] as String,
      tag: json['tag'] as int?,
      icon: StatusIcon.fromJson(json['icon'] as String?),
      hiddenDefault: json['hiddenDefault'] as bool? ??
          json['hidden_default'] as bool? ??
          false,
      done: json['done'] as bool? ?? false,
      todo: json['todo'] as bool? ?? false,
    );
  }
}

/// Declares how a [LinkTypeConfig] is composable from Plot.
///
/// Mirrors the Twister SDK's `ComposeConfig`. Attached to
/// [LinkTypeConfig.compose] — when null, the link type is sync-only and no
/// "Create new …" picker entry is emitted for it.
class ComposeConfig extends Equatable {
  /// Picker mode:
  /// - `'channels'` (default): one chip per enabled channel.
  /// - `'contacts'`: one chip per connection; user picks contacts.
  /// - `'addresses'`: one chip per connection; user types addresses.
  final String targets;
  /// Status to assign newly-created links. Should match an entry in the
  /// parent linkType's `statuses[]`, OR a symbolic id the connector
  /// resolves itself (e.g. Linear's per-team UUIDs). Null when the
  /// connector declares no compose status (e.g. Slack, Gmail).
  final String? status;
  /// Picker chip / "Create new …" override. Null falls back to
  /// [LinkTypeConfig.label].
  final String? label;

  const ComposeConfig({
    this.targets = 'channels',
    this.status,
    this.label,
  });

  /// Parse from a [LinkTypeConfig] JSON map. The compose block is a nested
  /// object at `compose`. Returns null when absent (sync-only link type).
  static ComposeConfig? fromJson(Map<String, dynamic> linkTypeJson) {
    final raw = linkTypeJson['compose'];
    if (raw is! Map<String, dynamic>) return null;
    return ComposeConfig(
      targets: raw['targets'] as String? ?? 'channels',
      status: raw['status'] as String?,
      label: raw['label'] as String?,
    );
  }

  @override
  List<Object?> get props => [targets, status, label];
}

@DataClassName('LinkRow')
class Links extends Table with SyncableTable, UuidTable, CreatedTable {
  BlobColumn get threadId => blob().nullable().map(const UuidConverter())();
  BlobColumn get priorityId => blob().nullable().map(const UuidConverter())();
  TextColumn get source => text().nullable()();
  DateTimeColumn get sourceCreatedAt =>
      dateTime().map(const LocalDateTimeConverter())();
  BlobColumn get authorId => blob().nullable().map(const ActorIdConverter())();
  BlobColumn get assigneeId =>
      blob().nullable().map(const ActorIdConverter())();
  BlobColumn get createdBy => blob().nullable().map(const UuidConverter())();
  TextColumn get title => text().nullable()();
  TextColumn get preview => text().nullable()();
  TextColumn get type => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get actions =>
      text().nullable().map(const UserActionsConverter())();
  TextColumn get meta => text().nullable().map(const JsonConverter())();
  TextColumn get sourceUrl => text().nullable()();
  TextColumn get channelId => text().nullable()();
  TextColumn get logo => text().nullable()();
  BlobColumn get mergedFromThreadId =>
      blob().nullable().map(const UuidConverter())();

  /// Connector-supplied primary-link ranking. The thread's single external
  /// link is the highest-priority non-archived canonical (note_scoped=false)
  /// link; ties break on earliest created_at. Mirrors `link.priority`.
  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// TRUE when this link is attached to a note (note.link_id), not the thread.
  /// Note-scoped links are excluded from thread-level surfacing and
  /// primary-link selection. Mirrors `link.note_scoped`.
  BoolColumn get noteScoped =>
      boolean().withDefault(const Constant(false))();

  /// Server access-loss tombstone marker. TRUE when the row arrived from
  /// user.link_redacted (a per-item connector removal with no bulk signal).
  /// The sync layer hard-deletes these locally (link + its schedules).
  BoolColumn get revoked => boolean().withDefault(const Constant(false))();
}

class LinksBase extends BaseTable {
  LinksBase({this.priorityId})
    : super(
        table: 'user_link',
        syncEndpoint: 'links',
        name: 'links',
        filterName: priorityId?.toString(),
        order: 'updated_at',
        ascending: false,
        supportsArchiving: false,
      );

  final PriorityId? priorityId;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      lastHorizon: lastHorizon,
      pageSeq: pageSeq,
      pageId: pageId,
      initial: initial,
      archived: archived,
    );
    if (priorityId != null) {
      params['priority_id'] = priorityId.toString();
    }
    return params;
  }

  @override
  Map<String, String> buildRangeParams(DateTimeRange range) {
    final params = <String, String>{};
    if (range.start != null) {
      params['range_start'] = range.start!.toIso8601String();
    }
    if (range.end != null) {
      params['range_end'] = range.end!.toIso8601String();
    }
    return params;
  }

  @override
  Insertable<LinkRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id');
    json.remove('twist_id');
    json.remove('source_priority_root');
    json.remove('priority_path');

    return LinkRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // Access-loss tombstones (user.link_redacted): a per-item connector
    // removal with no bulk signal. Hard-delete the local link + its schedules.
    final revokedIds = <Uint8List>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final linkRow = row as LinkRow;
      if (linkRow.revoked) {
        revokedIds.add(linkRow.id.toBytes());
        continue;
      }
      // Existing race protection (see SchedulesBase.processPulledRows): skip
      // rows with a pending local write.
      final local = await (store.select(store.links)
            ..where((l) => l.id.equals(linkRow.id.toBytes())))
          .getSingleOrNull();
      if (local != null && local.pending != null) continue;
      result.add(row);
    }
    if (revokedIds.isNotEmpty) {
      await Link._hardDeleteLinks(store, revokedIds);
    }
    return result;
  }
}

class Link extends Equatable {
  /// Synchronous per-thread links cache, keyed by thread id. Populated by
  /// [watchForThread] emissions and bulk-warmed by [primeForThreads] so a
  /// freshly-built [ThreadWidget] can seed its `_links` on first paint —
  /// otherwise the channel breadcrumb header (which is derived from the
  /// primary link's sharing model) is absent for the frame or two until the
  /// per-row Drift watch fires, popping the header in mid-transition. An
  /// empty list is a cached "no links" answer (distinct from a missing key).
  static final Map<ThreadId, List<Link>> _byThreadCache = {};

  /// The cached links for [threadId], or null when the thread has never been
  /// watched or primed. Callers seed first-paint state from this and rely on
  /// their own [watchForThread] subscription to keep it live afterwards.
  static List<Link>? cachedForThread(ThreadId threadId) =>
      _byThreadCache[threadId];

  /// Drop the synchronous links cache. Called on sign-out so a different user
  /// on the same device never seeds rows from the previous user's links.
  static void clearCache() {
    _byThreadCache.clear();
  }

  /// Bulk-warm [_byThreadCache] for [threadIds] in a single query so the next
  /// feed render has channel breadcrumbs ready. Only thread ids missing from
  /// the cache are queried — already-watched rows keep themselves live via
  /// [watchForThread], so re-priming them would be wasted work on incremental
  /// feed updates. Threads with no links are cached as empty lists so they're
  /// not re-queried on every rebuild.
  static Future<void> primeForThreads(Iterable<ThreadId> threadIds) async {
    final missing = <ThreadId>[
      for (final id in threadIds)
        if (!_byThreadCache.containsKey(id)) id,
    ];
    if (missing.isEmpty) return;
    final rows = await (Store.get.select(Store.get.links)
          ..where((l) => l.threadId.isIn(missing.map((i) => i.toBytes()))))
        .get();
    final grouped = <ThreadId, List<Link>>{};
    for (final row in rows) {
      final tid = row.threadId;
      if (tid == null) continue;
      (grouped[tid] ??= []).add(Link(row));
    }
    for (final id in missing) {
      _byThreadCache[id] = grouped[id] ?? const [];
    }
  }

  static Future<void> pull() async {
    await Store.get.pull(Store.get.links, LinksBase());
  }

  static Future<bool> push() async {
    return await Store.get.push(Store.get.links, LinksBase());
  }

  /// Hard-delete the given links and their schedules from the local DB.
  /// Drift doesn't enforce FK cascade locally, so schedules are deleted by
  /// linkId explicitly (link-schedules; thread-schedules are untouched).
  static Future<void> _hardDeleteLinks(
    Store store,
    List<Uint8List> linkIds,
  ) async {
    await store.transaction(() async {
      await (store.delete(store.schedules)
            ..where((s) => s.linkId.isIn(linkIds)))
          .go();
      await (store.delete(store.links)..where((l) => l.id.isIn(linkIds))).go();
    });
  }

  /// Purge all connector links owned by [instanceId] and their schedules.
  /// Driven by the synced twist_instance.archived_at signal (uninstall).
  static Future<void> hardDeleteForInstance(
    Store store,
    Uuid instanceId,
  ) async {
    final rows = await (store.select(store.links)
          ..where((l) => l.createdBy.equals(instanceId.toBytes())))
        .get();
    if (rows.isEmpty) return;
    await _hardDeleteLinks(store, rows.map((r) => r.id.toBytes()).toList());
  }

  /// Purge connector links owned by [instanceId] on [channelId] and their
  /// schedules. Driven by the synced channel.enabled=false signal.
  static Future<void> hardDeleteForChannel(
    Store store,
    Uuid instanceId,
    String channelId,
  ) async {
    final rows = await (store.select(store.links)
          ..where((l) =>
              l.createdBy.equals(instanceId.toBytes()) &
              l.channelId.equals(channelId)))
        .get();
    if (rows.isEmpty) return;
    await _hardDeleteLinks(store, rows.map((r) => r.id.toBytes()).toList());
  }

  final LinkRow _link;

  const Link(this._link);

  LinkId get id => _link.id;
  ThreadId? get threadId => _link.threadId;
  Uuid? get priorityId => _link.priorityId;
  String? get source => _link.source;
  DateTime get sourceCreatedAt => _link.sourceCreatedAt;
  ActorId? get authorId => _link.authorId;
  ActorId? get assigneeId => _link.assigneeId;
  Uuid? get createdBy => _link.createdBy;
  String? get title => _link.title;
  String? get preview => _link.preview;
  String? get type => _link.type;
  String? get status => _link.status;
  int get priority => _link.priority;
  bool get noteScoped => _link.noteScoped;
  List<UserAction>? get actions => _link.actions;
  Map<String, dynamic>? get meta => _link.meta;
  String? get sourceUrl => _link.sourceUrl;
  String? get channelId => _link.channelId;
  ThreadId? get mergedFromThreadId => _link.mergedFromThreadId;
  DateTime get createdAt => _link.createdAt;
  DateTime get updatedAt => _link.updatedAt;

  /// Get the LinkTypeConfig for this link.
  /// Checks channel-level linkTypes first (from channel),
  /// falling back to twist-level linkTypes (from twist_instance).
  LinkTypeConfig? getTypeConfig() {
    final ptId = createdBy;
    if (ptId == null || type == null) return null;

    // Check channel-level linkTypes first
    // Try exact channel match, then any channel for this source
    final sc = channelId != null
        ? Channel.findByChannel(ptId, channelId!)
        : null;
    final channelConfigs = (sc ?? Channel.findBySource(ptId))
        ?.parsedLinkTypes;
    if (channelConfigs != null) {
      final match = channelConfigs.where((c) => c.type == type).firstOrNull;
      if (match != null) return match;
    }

    // Fall back to twist-level linkTypes
    final pt = TwistInstance._cache[ptId];
    if (pt == null) return null;
    final configs = pt.parsedLinkTypes;
    if (configs == null) return null;
    return configs.where((c) => c.type == type).firstOrNull;
  }

  /// Get the human-readable status label, falling back to the raw status.
  String? get statusLabel {
    final config = getTypeConfig();
    if (config == null || status == null) return status;
    return config.statuses
            ?.where((s) => s.status == status)
            .firstOrNull
            ?.label ??
        status;
  }

  /// Get the logo URL from the link's type config, falling back to per-link logo.
  String? get logo => getTypeConfig()?.logo ?? _link.logo;

  /// Get the logo URL appropriate for the given [brightness].
  /// Falls back to per-link logo (e.g. favicon) when no type config exists.
  String? logoForBrightness(Brightness brightness) {
    final config = getTypeConfig();
    if (config != null) {
      if (brightness == Brightness.dark && config.logoDark != null) {
        return config.logoDark;
      }
      return config.logo ?? _link.logo;
    }
    return _link.logo;
  }

  /// Optimistically update the link's status and push to the server.
  static Future<void> updateStatus(Link link, String newStatus) async {
    final updated = link._link.copyWith(
      status: Value(newStatus),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(Store.get.links, updated.toCompanion(false), LinksBase());
  }

  /// Optimistically update the link's assignee and push to the server.
  static Future<void> updateAssignee(Link link, ActorId? newAssigneeId) async {
    final updated = link._link.copyWith(
      assigneeId: Value(newAssigneeId),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(Store.get.links, updated.toCompanion(false), LinksBase());
  }

  /// Update the user-editable title and URL of a link. Used by the pinned
  /// link row's edit menu — keep separate from connector-driven updates.
  static Future<void> updateTitleAndUrl(
    Link link, {
    required String? title,
    required String url,
  }) async {
    final updated = link._link.copyWith(
      title: Value(title),
      sourceUrl: Value(url),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      Store.get.links,
      updated.toCompanion(false),
      LinksBase(),
    );
  }

  /// Detach a link from its thread (Unpin). The link row is preserved so
  /// other clients see the change via incremental sync; setting thread_id
  /// to null removes it from [watchForThread] without a `DELETE` (which
  /// would be invisible to the seq cursor protocol).
  static Future<void> unpinFromThread(Link link) async {
    final updated = link._link.copyWith(
      threadId: const Value(null),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      Store.get.links,
      updated.toCompanion(false),
      LinksBase(),
    );
  }

  /// Find links by exact source URL match
  static Future<List<Link>> findBySourceUrl(String url) async {
    final rows = await (Store.get.select(
      Store.get.links,
    )..where((l) => l.sourceUrl.equals(url))).get();
    return rows.map((row) => Link(row)).toList();
  }

  /// Search links by title (case-insensitive substring match)
  static Future<List<Link>> searchByTitle(String query) async {
    final rows = await (Store.get.select(
      Store.get.links,
    )..where((l) => l.title.like('%$query%'))).get();
    return rows.map((row) => Link(row)).toList();
  }

  /// Most recently updated links that have a source URL, newest first.
  static Future<List<Link>> listRecent({int limit = 10}) async {
    final rows =
        await (Store.get.select(Store.get.links)
              ..where((l) => l.sourceUrl.isNotNull())
              ..orderBy([(l) => OrderingTerm.desc(l.updatedAt)])
              ..limit(limit))
            .get();
    return rows.map((row) => Link(row)).toList();
  }

  /// Get links for a given thread
  static Future<List<Link>> getForThread(ThreadId threadId) async {
    final rows = await (Store.get.select(
      Store.get.links,
    )..where((l) => l.threadId.equals(threadId.toBytes()))).get();
    return rows.map((row) => Link(row)).toList();
  }

  /// All locally-present links created by [connectionId] (a twist_instance id).
  /// Used to rank likely assignees within a connection in the assignee picker.
  /// [connectionId] is a `Uuid` (the owning twist_instance), not an `ActorId`.
  /// The local `links` table has no `archived_at`: connector removals arrive as
  /// revoked tombstones that are hard-deleted on pull, so present rows are live.
  static Future<List<Link>> getForConnection(Uuid connectionId) async {
    final rows = await (Store.get.select(Store.get.links)
          ..where((l) => l.createdBy.equals(connectionId.toBytes())))
        .get();
    return rows.map((row) => Link(row)).toList();
  }

  /// Watch canonical (thread-level) links for a given thread.
  ///
  /// Returns only non-note-scoped links (`noteScoped == false`), ordered
  /// primary-first: priority DESC, createdAt ASC, id ASC — matching
  /// [Thread.primaryLink] so `.first` here IS the primary link.
  ///
  /// Note-scoped links (attached to a note via `note.link_id`) are excluded;
  /// use [getForThread] when you need ALL links regardless of scope.
  ///
  /// Per-user link visibility lives server-side in `user.link`: each user
  /// only receives links from connector instances they own (plus user-authored
  /// links), so two users' connections of the same external resource no longer
  /// produce duplicate rows here.
  static Stream<List<Link>> watchForThread(ThreadId threadId) {
    final db = Store.get;
    return (db.select(db.links)
          ..where((l) =>
              l.threadId.equals(threadId.toBytes()) &
              l.noteScoped.equals(false))
          ..orderBy([
            // Primary-first: highest priority, then earliest created, then id
            // — matches [Thread.primaryLink] so `.first` here IS the primary.
            (l) => OrderingTerm.desc(l.priority),
            (l) => OrderingTerm.asc(l.createdAt),
            (l) => OrderingTerm.asc(l.id),
          ]))
        .watch()
        .map((rows) {
          final links = rows.map(Link.new).toList();
          // Keep the synchronous cache live for this thread so a later
          // remount seeds the correct channel breadcrumb on first paint.
          _byThreadCache[threadId] = links;
          return links;
        });
  }

  @override
  List<Object?> get props => [_link];
}
