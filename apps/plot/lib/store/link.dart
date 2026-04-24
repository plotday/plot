part of 'store.dart';

typedef LinkId = Uuid;

/// Describes a link type that a source creates.
class LinkTypeConfig {
  final String type;
  final String label;
  final String? logo;
  final String? logoDark;
  final String? logoMono;
  final List<LinkStatus>? statuses;
  final bool supportsAssignee;

  const LinkTypeConfig({
    required this.type,
    required this.label,
    this.logo,
    this.logoDark,
    this.logoMono,
    this.statuses,
    this.supportsAssignee = false,
  });

  factory LinkTypeConfig.fromJson(Map<String, dynamic> json) {
    return LinkTypeConfig(
      type: json['type'] as String,
      label: json['label'] as String,
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
    );
  }
}

/// A possible status value within a LinkTypeConfig.
class LinkStatus {
  final String status;
  final String label;
  final int? tag;
  final bool done;
  final bool todo;
  /// When true, this status is the default applied to items created via the
  /// connector's `onCreateLink`. At most one status per link type should
  /// set this. A link type opts in to Plot-initiated creation by declaring
  /// at least one status with `createDefault: true`.
  final bool createDefault;

  const LinkStatus({
    required this.status,
    required this.label,
    this.tag,
    this.done = false,
    this.todo = false,
    this.createDefault = false,
  });

  factory LinkStatus.fromJson(Map<String, dynamic> json) {
    return LinkStatus(
      status: json['status'] as String,
      label: json['label'] as String,
      tag: json['tag'] as int?,
      done: json['done'] as bool? ?? false,
      todo: json['todo'] as bool? ?? false,
      createDefault: json['createDefault'] as bool? ??
          json['create_default'] as bool? ??
          false,
    );
  }
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
}

class LinksBase extends BaseTable {
  LinksBase({this.priorityId, this.priorityPath})
    : super(
        table: 'user_link',
        syncEndpoint: 'links',
        name: 'links',
        filterName: priorityPath,
        order: 'updated_at',
        ascending: false,
        supportsArchiving: false,
      );

  final PriorityId? priorityId;
  final String? priorityPath;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
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
}

class Link extends Equatable {
  static Future<void> pull() async {
    await Store.get.pull(Store.get.links, LinksBase());
  }

  static Future<bool> push() async {
    return await Store.get.push(Store.get.links, LinksBase());
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

  /// Watch links for a given thread.
  ///
  /// Filters out links whose schedule has fully ended (upper bound in the past)
  /// when other links still have active/upcoming schedules. If all links have
  /// ended schedules, shows only the most recent one.
  static Stream<List<Link>> watchForThread(ThreadId threadId) {
    final db = Store.get;
    final sched = db.alias(db.schedules, 'link_sched');
    final query = db.select(db.links).join([
      leftOuterJoin(
        sched,
        sched.linkId.equalsExp(db.links.id) &
            sched.occurrence.isNull() &
            sched.archivedAt.isNull(),
      ),
    ])
      ..where(db.links.threadId.equals(threadId.toBytes()));

    return query.watch().map((rows) {
      final now = DateTime.now();
      final activeLinks = <Link>[];
      Link? mostRecentEnded;
      DateTime? mostRecentEndTime;
      final seen = <Uuid>{};

      for (final row in rows) {
        final linkRow = row.readTable(db.links);
        if (!seen.add(linkRow.id)) continue;
        final schedule = row.readTableOrNull(sched);
        final link = Link(linkRow);

        if (schedule == null) {
          activeLinks.add(link);
          continue;
        }

        final endTime = schedule.endAt ?? schedule.endOn?.toDateTime();
        if (endTime == null || endTime.isAfter(now)) {
          activeLinks.add(link);
        } else {
          if (mostRecentEndTime == null || endTime.isAfter(mostRecentEndTime)) {
            mostRecentEndTime = endTime;
            mostRecentEnded = link;
          }
        }
      }

      if (activeLinks.isNotEmpty) return activeLinks;
      if (mostRecentEnded != null) return [mostRecentEnded];
      return rows.map((r) => Link(r.readTable(db.links))).toList();
    });
  }

  @override
  List<Object?> get props => [_link];
}
