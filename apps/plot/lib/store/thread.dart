part of 'store.dart';

/// SQLite JSON path for an emoji key, e.g. `'$."🔥"'`. Emoji content is
/// user-controlled (custom-emoji refs include arbitrary names), so escape
/// backslash and double-quote before inlining.
String emojiJsonPath(Reaction emoji) {
  final escaped = emoji.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return "'\$.\"$escaped\"'";
}

typedef ThreadId = Uuid;
typedef ThreadWatchResult = ({
  List<Thread> threads,
  int rawRowCount,

  /// Tail cursor for the last thread in this emission, populated only by
  /// the activity-feed fast path. The bloc uses this for cursor-paginated
  /// fetch-more so the cursor matches the SQL's ordering exactly (Dart-
  /// side derivation from `Thread.activityAt` doesn't match the SQL
  /// formula in all cases).
  ({int unreadSort, String activityAt, ThreadId id})? feedTailCursor,
});

/// Page result for the activity feed cursor pagination. See
/// [Thread.fetchActivityFeedPage]. [nextCursor] is the tail of this page
/// (use as `after` for the next fetch); null when the page is empty.
/// [saturated] is true when the query returned LIMIT rows, suggesting
/// more pages may exist locally.
typedef ActivityFeedPage = ({
  List<Thread> threads,
  ({int unreadSort, String activityAt, ThreadId id})? nextCursor,
  bool saturated,
});

@DataClassName('ThreadRow')
class Threads extends Table
    with SyncableTable, UuidTable, CreatedTable, DraftTable, DeletableTable {
  // Vestigial: the server's per-user thread view still exposes `priority_id`
  // (joined from thread_priority) so the client keeps this as a denormalized
  // "my current filing" pointer. Peer filings live in `thread_priorities`.
  BlobColumn get priorityId => blob().map(const UuidConverter())();

  /// Everyone the thread is shared with, as contact ids. Includes the
  /// author's primary contact for human-authored threads. Populated from
  /// `thread.contacts` on the server.
  TextColumn get contacts => text().nullable().map(const UuidListConverter())();

  /// Contacts who were on this thread but have been dropped from the active
  /// recipient set. They remain in `contacts` (for thread visibility) but are
  /// excluded from outbound defaults, the header AvatarGroup, and badge logic.
  /// Populated from `thread.dropped_contacts` on the server.
  TextColumn get droppedContacts =>
      text().nullable().map(const UuidListConverter())();

  /// Per-contact descriptive metadata, keyed by contact id. Shape (JSON):
  ///   `{ "<contact_uuid>": { "role": "<role_id>", "addedBy": "<user_id>" } }`
  /// Populated from `thread.contact_meta` on the server. Contacts not in the
  /// map use the link type's default role. Hidden roles are filtered
  /// server-side before sync.
  TextColumn get contactMeta => text().nullable().map(const JsonConverter())();

  /// Group IDs attached to this thread for dynamic visibility.
  TextColumn get groups => text().nullable().map(const UuidListConverter())();

  /// Routing key used by priority rules. Defaults (server-side) to the first
  /// group id stringified, or to `channel:<id>` for connection-sourced threads.
  TextColumn get topic => text().nullable()();

  /// Team scope for this thread, mirroring `thread.team_id` on the server
  /// (a `bigint` reference). NULL means the thread is Personal (not scoped to
  /// a team). Server-immutable after create; round-trips through sync so the
  /// scope is preserved across devices. Set at draft creation time only.
  Int64Column get teamId => int64().nullable()();

  /// Pending email invitations stored locally until the next sync push.
  /// The server resolves these to contacts and clears them.
  TextColumn get inviteEmails => text().nullable()();

  TextColumn get title => text().nullable()();
  TextColumn get preview => text().nullable()();

  DateTimeColumn get lastNoteCreatedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get lastNoteSourceCreatedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();
  IntColumn get importance => integer().withDefault(const Constant(0))();

  /// Three independent per-user state booleans, set with high confidence by
  /// the AI/connector and/or directly by the user:
  ///   active  — user is acting on (or about to act on) this thread now.
  ///             Drives the Doing section of the unified feed.
  BoolColumn get active => boolean().withDefault(const Constant(false))();

  /// True when the user should be notified immediately rather than waiting
  /// for the next see_within window. Bypasses the importance >= 50 gate.
  BoolColumn get urgent => boolean().nullable()();

  /// Drag-to-reorder position within the Doing section of the unified feed
  /// (and within a single day of the Scheduled section). Previously stored
  /// on the per-user schedule row.
  RealColumn get stateOrder => real().nullable().map(const OrderConverter())();

  /// Per-user "do on this date" intent (daterange lower bound). Previously
  /// stored on the per-user schedule row.
  TextColumn get stateOn => text().nullable().map(const DateConverter())();

  /// Per-user "do at this time" intent (tstzrange lower bound). Previously
  /// stored on the per-user schedule row.
  DateTimeColumn get stateAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();

  DateTimeColumn get readAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get bumpedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get icon => text().nullable()();

  /// The contact (or twist_instance) credited with causing this thread's
  /// creation. User threads: the user's primary contact. Connector threads:
  /// the resolved external link author. Non-connection twist threads: the
  /// twist. Synced from user.thread; not yet surfaced in the UI.
  BlobColumn get authorId =>
      blob().nullable().map(const ActorIdConverter())();

  /// Whether the thread has a content embedding on the server.
  /// Used to decide whether "move similar" rule options are available.
  BoolColumn get hasEmbedding => boolean().withDefault(const Constant(false))();

  /// "Skip active for threads like this" mute anchor (per-user, mirrored
  /// from `thread_priority.mute_by_thread_id`). NULL when not muted. Equal
  /// to this thread's own id when the user invoked the command on this
  /// thread (the seed). Otherwise points to the seed whose rule swept this
  /// thread. Toggling the broom off on any thread carrying a non-null flag
  /// reverses the rule for every related thread.
  BlobColumn get muteByThreadId =>
      blob().nullable().map(const UuidConverter())();

  /// When set, this thread was merged into the referenced thread and is
  /// archived; its identity columns are preserved on this row so a Split
  /// can restore them.
  BlobColumn get mergedIntoThreadId =>
      blob().nullable().map(const UuidConverter())();

  /// Thread-level assignee (contact id), mirrored from `thread.assignee_id`
  /// on the server. Mutable; for connector threads it tracks the primary
  /// assignment-capable link's assignee.
  BlobColumn get assigneeId =>
      blob().nullable().map(const ActorIdConverter())();

  /// Server-side access-loss tombstone marker. TRUE when the row arrived
  /// from `user.thread_redacted` — the user lost access (removed from a
  /// group, removed from a team) and the row carries no meaningful data.
  /// The sync layer hard-deletes these rows locally (along with their
  /// dependent notes/links/schedules) so they never reach the UI. Persisted
  /// only as a transient state during the sync pass — a row that's still
  /// `revoked = true` in the local DB means hard-delete didn't run.
  BoolColumn get revoked => boolean().withDefault(const Constant(false))();
}

@DataClassName('ScheduleRow')
class Schedules extends Table with SyncableTable, UuidTable {
  static String formatOccurrence(DateTime dateTime, {bool dateOnly = false}) {
    if (dateOnly) {
      return '${dateTime.year.toString().padLeft(4, '0')}-'
          '${dateTime.month.toString().padLeft(2, '0')}-'
          '${dateTime.day.toString().padLeft(2, '0')}';
    } else {
      return '${dateTime.year.toString().padLeft(4, '0')}-'
          '${dateTime.month.toString().padLeft(2, '0')}-'
          '${dateTime.day.toString().padLeft(2, '0')}T'
          '${dateTime.hour.toString().padLeft(2, '0')}:'
          '${dateTime.minute.toString().padLeft(2, '0')}';
    }
  }

  /// Normalize a stored occurrence string to the canonical
  /// [formatOccurrence] form used by client-generated recurrence instances.
  /// The server writes occurrence as `Date.toISOString()` (UTC ISO), but
  /// generated instances are keyed in local-naive `YYYY-MM-DDTHH:MM` form,
  /// so without this both keys end up in the dedup map and the user sees
  /// the original instance alongside the rescheduled one.
  static String canonicalOccurrence(String stored, {required bool dateOnly}) {
    final parsed = DateTime.tryParse(stored);
    if (parsed == null) return stored;
    // Date-only events are TZ-agnostic (Google sends `originalStartTime.date`
    // as `YYYY-MM-DD`, which the API serialises as UTC midnight) — keep the
    // calendar date as-is rather than shifting it across the user's TZ.
    if (dateOnly) return formatOccurrence(parsed, dateOnly: true);
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    return formatOccurrence(local, dateOnly: false);
  }

  DateTimeColumn get startAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get endAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get startOn => text().nullable().map(const DateConverter())();
  TextColumn get endOn => text().nullable().map(const DateConverter())();
  TextColumn get recurrenceRule =>
      text().nullable().map(const RecurrenceRuleConverter())();
  IntColumn get duration =>
      integer().nullable().map(const IntervalConverter())();
  TextColumn get recurrenceExdates =>
      text().nullable().map(const DateTimeListConverter())();
  TextColumn get occurrence => text().nullable()();
  DateTimeColumn get archivedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  BlobColumn get threadId => blob().nullable().map(const UuidConverter())();
  BlobColumn get linkId => blob().nullable().map(const UuidConverter())();
  TextColumn get contacts => text().nullable()();
  TextColumn get currentUserStatus => text().nullable()();
  TextColumn get reason => text().nullable()();
}

@DataClassName('ThreadAssociationRow')
class ThreadAssociations extends Table with SyncableTable, UuidTable {
  BlobColumn get parentThreadId => blob().map(const UuidConverter())();
  BlobColumn get childThreadId => blob().map(const UuidConverter())();
  RealColumn get order => real().map(const OrderConverter())();
  DateTimeColumn get archivedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class ScheduleContact {
  final String contactId;
  final String? contactEmail;
  final String? contactName;
  final String? contactUserId;
  final String? status;
  final String? role;

  const ScheduleContact({
    required this.contactId,
    this.contactEmail,
    this.contactName,
    this.contactUserId,
    this.status,
    this.role,
  });

  factory ScheduleContact.fromJson(Map<String, dynamic> json) {
    return ScheduleContact(
      contactId: json['contact_id'] as String,
      contactEmail: json['contact_email'] as String?,
      contactName: json['contact_name'] as String?,
      contactUserId: json['contact_user_id'] as String?,
      status: json['status'] as String?,
      role: json['role'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'contact_id': contactId,
    if (contactEmail != null) 'contact_email': contactEmail,
    if (contactName != null) 'contact_name': contactName,
    if (contactUserId != null) 'contact_user_id': contactUserId,
    if (status != null) 'status': status,
    if (role != null) 'role': role,
  };
}

class RecurrenceRuleConverter extends TypeConverter<RecurrenceRule?, String?>
    with JsonTypeConverter2<RecurrenceRule?, String?, String?> {
  const RecurrenceRuleConverter();

  @override
  RecurrenceRule? fromSql(String? fromDb) {
    if (fromDb == null || fromDb.isEmpty) {
      return null;
    }
    try {
      return RecurrenceRule.fromString(fromDb);
    } catch (e) {
      // Return null for invalid RRULE strings
      return null;
    }
  }

  @override
  String? toSql(RecurrenceRule? value) => value?.toString();

  @override
  RecurrenceRule? fromJson(String? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    try {
      // If the JSON doesn't start with "RRULE:", add it
      final ruleString = json.startsWith('RRULE:') ? json : 'RRULE:$json';
      return RecurrenceRule.fromString(ruleString);
    } catch (e) {
      // Return null for invalid RRULE strings
      return null;
    }
  }

  @override
  String? toJson(RecurrenceRule? value) {
    if (value == null) return null;
    final ruleString = value.toString();
    // Remove "RRULE:" prefix for JSON serialization if present
    return ruleString.startsWith('RRULE:')
        ? ruleString.substring(6)
        : ruleString;
  }
}

class ThreadsBase extends BaseTable {
  ThreadsBase({
    this.priorityId,
    this.priorityPath,
    this.initial = false,
    String? syncName,
    String? sortBy,
    super.ascending = false,
  }) : super(
         table: 'user_thread',
         syncEndpoint: 'threads',
         name: syncName ?? "threads",
         filterName: priorityPath,
         order: sortBy ?? 'activity_at',
         limit: initial
             ? null
             : 200, // No limit for initial pull (active OR unread)
       );

  final PriorityId? priorityId;
  final String? priorityPath;
  final bool initial;

  /// Thread IDs that should be auto-filed by the server after push.
  /// Populated by NewThreadPage when sparkles (auto-file) is selected;
  /// consumed and cleared during push.
  static final Set<String> autoFileIds = {};

  /// Pending create-link payloads keyed by thread id. Populated when the user
  /// picks "Create new X" in the Add link modal. On push, the payload is
  /// spread into the thread row body so the server can dispatch to the
  /// connector's onCreateLink after the thread is upserted and titled.
  ///
  /// Shape: `{ 'create_link': { twist_instance_id, channel_id, type, status },
  ///          'note_content': String | null }`.
  static final Map<String, Map<String, dynamic>> pendingCreateLinks = {};

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
  String? parseBoundaryValue(String? value) {
    if (value == null || order != 'agenda_at') return value;
    // agenda_at is a tstzrange like '["2026-03-15 15:30:00+00",infinity]'
    // Extract the lower bound for use as the pagination boundary.
    final inner = value.replaceAll(RegExp(r'[\[\]()"]'), '');
    final lower = inner.split(',').first.trim();
    return lower.isEmpty ? null : lower;
  }

  @override
  Insertable<ThreadRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id');
    json.remove('activity_at');
    json.remove('agenda_at');
    json.remove('invite_emails');

    // state_on / state_at arrive from the server as Postgres range literals
    // (`[lower,upper)`, or `empty`). The local model stores only the lower
    // bound; collapse the range here so the row deserializer sees a scalar
    // date / timestamp instead of failing to parse the bracketed form.
    final rawStateOn = json['state_on'];
    if (rawStateOn is String) {
      json['state_on'] = rawStateOn == 'empty'
          ? null
          : DateRange.fromString(rawStateOn).start?.toString();
    }
    final rawStateAt = json['state_at'];
    if (rawStateAt is String) {
      json['state_at'] = rawStateAt == 'empty'
          ? null
          : DateTimeRange.fromString(
              rawStateAt,
            ).start?.toUtc().toIso8601String();
    }

    // contact_meta must be an object keyed by contact_id. A malformed
    // non-object value (e.g. the `[{}, null]` array an old upsert_thread bug
    // produced when merging a JSON-null payload) would crash the Map cast in
    // ThreadRow.fromJson — and since pull() aborts cursor advance on any
    // row-parse failure, a single bad row permanently wedges all thread sync.
    // Degrade a bad shape to null (the model reads null as "no meta") so one
    // corrupt row can't stall the whole pull.
    final rawContactMeta = json['contact_meta'];
    if (rawContactMeta != null && rawContactMeta is! Map) {
      json['contact_meta'] = null;
    }

    // Drift's default serializer can't cast int/String to BigInt; convert explicitly.
    // pg driver may return bigint as int (with type parser) or String (without).
    final rawTeamId = json['team_id'];
    if (rawTeamId is int) {
      json['team_id'] = BigInt.from(rawTeamId);
    } else if (rawTeamId is String) {
      json['team_id'] = BigInt.parse(rawTeamId);
    }

    return ThreadRow.fromJson(json);
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
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // Access-loss tombstones (user.thread_redacted). The server emits these
    // rows with revoked=true when the user has lost access (group removal,
    // team-leave). Hard-delete the local thread + dependent rows so they
    // disappear entirely from the client — they can't be unarchived by the
    // user and contain no useful data, so they don't belong in archives.
    // See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
    final revokedIds = <Uint8List>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final activityRow = row as ThreadRow;
      if (activityRow.revoked) {
        revokedIds.add(activityRow.id.toBytes());
        continue;
      }
      final local = await (store.select(
        store.threads,
      )..where((t) => t.id.equals(activityRow.id.toBytes()))).getSingleOrNull();
      var merged = activityRow;

      // Conflict resolution: local has a pending read (readAt != null).
      if (local != null && local.readAt != null) {
        if (local.active) {
          // Active thread: read_at is the durable
          // "finished" marker that drives section placement (Doing →
          // Activity on finish). The user.thread server view does not
          // expose read_at, so local is the source of truth. Preserve it
          // through the merge — without this, insertOrReplace
          // (store.dart:1381) overwrites local read_at with the server's
          // null and the thread re-appears in Doing.
          merged = merged.copyWith(readAt: Value(local.readAt));
        } else {
          final serverContent =
              activityRow.lastNoteSourceCreatedAt ?? activityRow.createdAt;

          if (activityRow.unread == false) {
            // Server agrees thread is read — clear local readAt
            merged = merged.copyWith(readAt: const Value(null));
          } else if (serverContent.isAfter(local.readAt!)) {
            // Server says unread AND there's new content since we read
            // → accept server's unread state, clear readAt
            merged = merged.copyWith(readAt: const Value(null));
          } else {
            // Server says unread but no new content — keep local read
            merged = merged.copyWith(
              unread: false,
              importance: 0,
              active: false,
              urgent: const Value(null),
              readAt: Value(local.readAt),
            );
          }
        }
      }

      // Preserve a locally-bumped `bumpedAt` that the server hasn't echoed
      // back yet. Without this, a pull that races our push (which happens
      // on the next sync tick via `/sync/thread-unread`) replaces the
      // local NOW value with the server's older one and the finished
      // thread drops from the top of Done to its prior activity position.
      if (local != null && local.bumpedAt != null) {
        final serverBumped = activityRow.bumpedAt;
        if (serverBumped == null || local.bumpedAt!.isAfter(serverBumped)) {
          merged = merged.copyWith(bumpedAt: Value(local.bumpedAt));
        }
      }

      result.add(merged);
    }

    if (revokedIds.isNotEmpty) {
      await _hardDeleteRevokedThreads(store, revokedIds);
    }

    return result;
  }

  /// Hard-delete revoked threads and their dependent rows from the local DB.
  /// Drift tables don't enforce FK cascade locally, so we do it manually.
  static Future<void> _hardDeleteRevokedThreads(
    Store store,
    List<Uint8List> threadIds,
  ) async {
    await store.transaction(() async {
      await (store.delete(
        store.notes,
      )..where((n) => n.threadId.isIn(threadIds))).go();
      await (store.delete(
        store.links,
      )..where((l) => l.threadId.isIn(threadIds))).go();
      await (store.delete(
        store.schedules,
      )..where((s) => s.threadId.isIn(threadIds))).go();
      await (store.delete(
        store.threads,
      )..where((t) => t.id.isIn(threadIds))).go();
    });
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Convert author_id from ActorId bytes to UUID string for the API
    // The client sets this correctly to Base.actorId (contact ID)
    // Do NOT remove - the sync API needs it to set the correct author

    // Remove per-user thread_state fields — they are managed separately via
    // /sync/thread-state (active / urgent / importance / order / on / at /
    // read_at all live there, not on the shared thread row).
    json.remove('unread');
    json.remove('importance');
    json.remove('active');
    json.remove('urgent');
    json.remove('state_order');
    json.remove('state_on');
    json.remove('state_at');
    json.remove('read_at');

    // Remove last_note_created_at and last_note_source_created_at - they are calculated fields from notes
    json.remove('last_note_created_at');
    json.remove('last_note_source_created_at');

    // Remove has_embedding - computed server-side from thread.embedding
    json.remove('has_embedding');

    // Signal server-side auto-filing for sparkles priority selection
    final id = json['id']?.toString();
    if (id != null && autoFileIds.remove(id)) {
      json['auto_file'] = true;
    }

    // Attach connector create-link payload if set. Consumed once so resending
    // the thread (e.g. retry) does not re-trigger item creation.
    if (id != null) {
      final pending = pendingCreateLinks.remove(id);
      if (pending != null) {
        json.addAll(pending);
      }
    }

    // Convert invite_emails from stored string to JSON array for the API,
    // then clear the local field so it's only sent once.
    final inviteEmails = json.remove('invite_emails');
    if (inviteEmails != null && (inviteEmails as String).isNotEmpty) {
      json['invite_emails'] = jsonDecode(inviteEmails);
    }

    return json;
  }
}

class SchedulesBase extends BaseTable {
  SchedulesBase({this.priorityId, this.priorityPath})
    : super(
        table: 'user_schedule',
        syncEndpoint: 'schedules',
        name: "schedules",
        filterName: priorityPath,
        order: 'updated_at',
        ascending: false,
      );

  final PriorityId? priorityId;
  final String? priorityPath;

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
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Convert start_at/end_at back to 'at' (tstzrange)
    final startAt = json.remove('start_at') as String?;
    final endAt = json.remove('end_at') as String?;
    if (startAt != null || endAt != null) {
      json['at'] = '[${startAt ?? ''},${endAt ?? ''})';
    }

    // Convert start_on/end_on back to 'on' (daterange)
    final startOn = json.remove('start_on') as String?;
    final endOn = json.remove('end_on') as String?;
    if (startOn != null || endOn != null) {
      json['on'] = '[${startOn ?? ''},${endOn ?? ''})';
    }

    // Remove local-only fields
    json.remove('contacts');
    json.remove('current_user_status');

    // Occurrence override rows must never carry the parent series'
    // recurrence_rule / recurrence_exdates — the DB enforces this via
    // schedule_recurrence_xor_occurrence.
    if (json['occurrence'] != null) {
      json.remove('recurrence_rule');
      json.remove('recurrence_exdates');
    }

    // DB constraint requires exactly one of at/on to be set on schedule (no
    // more per-user undated rows — per-user "do on date" intent lives on
    // thread_state). Default to today when neither is present.
    if (!json.containsKey('at') && !json.containsKey('on')) {
      final today = Time.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      json['on'] = '[$dateStr,)';
    }

    return json;
  }

  @override
  Insertable<ScheduleRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    // user_id is the row owner from the user.schedule view; the schedule
    // table itself no longer has a user_id column. Drop it on the way in.
    json.remove('user_id');
    json.remove('schedule_user_id');
    json.remove('priority_path');
    json.remove('range_at');
    json.remove('range_on');
    // Retired schedule columns — still present in older sync payloads but no
    // longer stored locally. They now live on thread_state.
    json.remove('order');
    json.remove('action');
    json.remove('outstanding_tasks');

    // Store contacts as JSON string and extract current user's RSVP status
    final contacts = json.remove('contacts');
    if (contacts is List && contacts.isNotEmpty) {
      json['contacts'] = jsonEncode(contacts);
      final userId = Base.userId.toString();
      String? bestStatus;
      for (final contact in contacts) {
        if (contact is Map && contact['contact_user_id'] == userId) {
          final status = contact['status'] as String?;
          if (status == 'attend') {
            bestStatus = 'attend';
            break; // attend is highest priority
          } else if (status == 'skip' && bestStatus == null) {
            bestStatus = 'skip';
          }
        }
      }
      if (bestStatus != null) {
        json['current_user_status'] = bestStatus;
      }
    }

    // Handle the 'at' field
    final at = json['at'] != null && json['at'] != 'empty'
        ? DateTimeRange.fromString(json['at'] as String)
        : null;
    json['start_at'] = at?.start?.toDb();
    json['end_at'] = at?.end?.toDb();
    json.remove('at');

    // Handle the 'on' field
    final on = json['on'] != null && json['on'] != 'empty'
        ? DateRange.fromString(json['on'] as String)
        : null;
    json['start_on'] = on?.start?.toString();
    json['end_on'] = on?.end?.toString();
    json.remove('on');

    return ScheduleRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // A pull racing with an in-flight push (e.g. broadcast for an unrelated
    // schedule wakes the orchestrator while our own archive is mid-flight)
    // would otherwise insertOrReplace the local row with the pre-push
    // server snapshot, dropping the user's pending change. Skip rows that
    // still have local pending bits — the next pull after push completes
    // will pick up the server's authoritative state.
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final scheduleRow = row as ScheduleRow;
      final local = await (store.select(
        store.schedules,
      )..where((s) => s.id.equals(scheduleRow.id.toBytes()))).getSingleOrNull();
      if (local != null && local.pending != null) continue;
      result.add(row);
    }
    return result;
  }
}

class ThreadAssociationsBase extends BaseTable {
  ThreadAssociationsBase()
    : super(
        table: 'user_thread_association',
        syncEndpoint: 'thread-associations',
        name: "thread_associations",
        order: 'updated_at',
        ascending: false,
      );

  @override
  Insertable<ThreadAssociationRow> fromBase(Map<String, dynamic> json) {
    // Remove view-only fields
    json.remove('user_id');
    return ThreadAssociationRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // See SchedulesBase.processPulledRows — same race protection.
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final assocRow = row as ThreadAssociationRow;
      final local = await (store.select(
        store.threadAssociations,
      )..where((a) => a.id.equals(assocRow.id.toBytes()))).getSingleOrNull();
      if (local != null && local.pending != null) continue;
      result.add(row);
    }
    return result;
  }
}

enum ThreadOrder { sorted, reverse }

class Thread extends Equatable implements Comparable<Thread> {
  /// Sentinel date meaning "to do now" (no specific schedule date).
  static final todoNowDate = Date(1970, 1, 1);

  static Future<void> pullInitial() async {
    // Set pulledAt baseline for links so future incremental pulls work.
    // Links for visible threads are fetched via pullTo in pullAgenda/pullActivityFeed.
    await Store.get.pull(Store.get.links, LinksBase());

    // Pull unread activities (no limit)
    // We do this to ensure we can reflect which priorities have unread activities.
    await Store.get.pull(
      Store.get.threads,
      ThreadsBase(initial: true),
      initial: true,
    );

    // Pull schedules so they survive fullResync orphan cleanup
    await Store.get.pull(Store.get.schedules, SchedulesBase(), initial: true);
    await Store.get.pull(
      Store.get.threadAssociations,
      ThreadAssociationsBase(),
      initial: true,
    );

    // Fetch current agenda and recent feed so views have data immediately
    await Thread.pullAgenda(null, null);
    await Thread.pullActivityFeed(null, null);
  }

  static Future<void> pull() async {
    // Pull links first so activity_at can be computed correctly when threads arrive.
    await Store.get.pull(Store.get.links, LinksBase());
    await Store.get.pull(Store.get.threads, ThreadsBase());
    await Store.get.pull(Store.get.schedules, SchedulesBase());
    await Store.get.pull(Store.get.threadTags, ThreadTagsBase());
    await Store.get.pull(Store.get.threadReactions, ThreadReactionsBase());
    await Store.get.pull(
      Store.get.threadAssociations,
      ThreadAssociationsBase(),
    );
  }

  /// Targeted fetch of specific thread rows by id, used by the notification
  /// tap flow to make the destination page render without waiting on a full
  /// cursor pull. Deliberately bypasses `sync_states`: the next regular
  /// cursor pull still covers these ids (insertOrReplace is idempotent), so
  /// we don't risk advancing a horizon past unfetched rows.
  ///
  /// Returns the ids that were successfully written to the local store
  /// (excludes ids the server filtered out — e.g. lost visibility).
  static Future<Set<ThreadId>> prefetchByIds(List<ThreadId> ids) async {
    if (ids.isEmpty || !Store.isAvailable) return const {};
    final idsParam = ids.map((id) => id.toString()).join(',');
    final List<dynamic> response = await api.get<List<dynamic>>(
      '/sync/threads/by-ids?ids=$idsParam',
    );
    final base = ThreadsBase();
    final rawRows = response.cast<Map<String, dynamic>>();
    final returnedIds = <ThreadId>{};
    final parsed = rawRows.expand<Insertable<ThreadRow>>((r) {
      try {
        final row = base.fromBase(r);
        final idStr = r['id'] as String?;
        if (idStr != null) returnedIds.add(Uuid.fromString(idStr));
        return [row];
      } catch (e, stackTrace) {
        log.warning("Error parsing thread row in prefetchByIds", e, stackTrace);
        return [];
      }
    }).toList();
    if (parsed.isEmpty) return const {};
    final processed = await base.processPulledRows(Store.get, parsed);
    await Store.get.batch((batch) {
      batch.insertAll(
        Store.get.threads,
        processed,
        mode: InsertMode.insertOrReplace,
      );
    });
    return returnedIds;
  }

  /// Pull one page of activity feed (backward from now).
  /// Uses SyncState entity "activity-feed:{priorityPath}" to track position.
  ///
  /// This method is also called from `_threadCritical` in the initial sync
  /// critical path (alongside `pullAgenda`), so it MUST remain bounded —
  /// a single `pullTo` slice for threads plus parallel `pullTo` slices for
  /// links/schedules/threadTags scoped to that slice. Do not add an
  /// unbounded `Store.pull(...)` call here; that's what blew the 30s
  /// critical budget for accounts with large link histories.
  static Future<void> pullActivityFeed(
    PriorityId? priorityId,
    Path? priorityPath, {
    bool archived = false,
  }) async {
    final path = priorityPath?.value ?? '';

    final pulledTo = await Store.get.pullTo(
      Store.get.threads,
      ThreadsBase(
        priorityId: priorityId,
        priorityPath: path,
        syncName: 'activity-feed',
        sortBy: 'activity_at',
        ascending: false,
      ),
      ascending: false,
      archived: archived,
    );

    if (pulledTo == null) return;

    await Future.wait([
      Store.get.pullTo(
        Store.get.links,
        LinksBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: false,
        archived: archived,
      ),
      Store.get.pullTo(
        Store.get.schedules,
        SchedulesBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: false,
        archived: archived,
      ),
      Store.get.pullTo(
        Store.get.threadTags,
        ThreadTagsBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: false,
        archived: archived,
      ),
    ]);
  }

  /// Pull one page of agenda (forward from today).
  /// Uses SyncState entity "agenda:{priorityPath}" to track position.
  ///
  /// Also called from `_threadCritical` in the initial sync critical path.
  /// See `pullActivityFeed` for the bounded-pull invariant — same rules
  /// apply here.
  static Future<void> pullAgenda(
    PriorityId? priorityId,
    Path? priorityPath, {
    bool archived = false,
  }) async {
    final path = priorityPath?.value ?? '';

    final pulledTo = await Store.get.pullTo(
      Store.get.threads,
      ThreadsBase(
        priorityId: priorityId,
        priorityPath: path,
        syncName: 'agenda',
        sortBy: 'agenda_at',
        ascending: true,
      ),
      ascending: true,
      archived: archived,
      rangeStart: Time.now().toUtc(),
    );

    if (pulledTo == null) return;

    await Future.wait([
      Store.get.pullTo(
        Store.get.links,
        LinksBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: true,
        archived: archived,
      ),
      Store.get.pullTo(
        Store.get.schedules,
        SchedulesBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: true,
        archived: archived,
      ),
      Store.get.pullTo(
        Store.get.threadTags,
        ThreadTagsBase(priorityId: priorityId, priorityPath: path),
        pullTo: pulledTo,
        ascending: true,
        archived: archived,
      ),
    ]);
  }

  static Future<bool> push() async {
    // Bail out if the Store has already been removed from the Injector.
    // Fire-and-forget callers (bare `Thread.push();` and
    // `_deferIdle(Thread.push, ...)`) can fire after sign-out / account
    // switch / shutdown drain, when `Store.get` would throw
    // NotDefinedException. The sync orchestrator already guards before
    // calling pushFn, so this is the load-bearing check for those paths.
    if (!Store.isAvailable) return false;

    // Run all five sub-pushes in parallel. They write to independent
    // tables and share no ordering requirements (the per-table push
    // already serialises against itself via _pushCompleters), so
    // serialising them with `&& await` added the sum of their claim
    // times — measured ~1.6s on a quiet sync where the max was ~1.1s.
    final results = await Future.wait([
      Store.get.push(Store.get.threads, ThreadsBase()),
      Store.get.push(Store.get.links, LinksBase()),
      Store.get.push(Store.get.schedules, SchedulesBase()),
      Store.get.push(Store.get.threadAssociations, ThreadAssociationsBase()),
      Store.get.push(Store.get.threadTags, ThreadTagsBase()),
      Store.get.push(Store.get.threadReactions, ThreadReactionsBase()),
    ]);
    final success = results.every((r) => r);

    // Push pending read changes (readAt != null means user read locally).
    // Threads with any state flag (active / task / toRead) sync read_at via
    // the per-user state endpoint (/sync/thread-state) and rely on local
    // read_at as a durable "finished" marker so they leave Doing and land
    // in Activity. They must NOT go through this endpoint — it would clear
    // local read_at after push and un-finish them.
    final readActivities = await (Store.get.select(
      Store.get.threads,
    )..where((t) => t.readAt.isNotNull() & t.active.equals(false))).get();

    if (readActivities.isEmpty) {
      return success;
    }

    try {
      final records = readActivities
          .map(
            (activity) => <String, dynamic>{
              'thread_id': activity.id.toString(),
              'read_at': activity.readAt!.toUtc().toIso8601String(),
              if (activity.bumpedAt != null)
                'bumped_at': activity.bumpedAt!.toUtc().toIso8601String(),
            },
          )
          .toList();

      final response = await api.post<dynamic>(
        '/sync/thread-unread',
        body: records,
      );

      // Handle server-rejected threads (no access)
      if (response is Map && response['failed'] is List) {
        final failedIds = (response['failed'] as List).cast<String>();
        if (failedIds.isNotEmpty) {
          log.warning(
            'Server rejected ${failedIds.length} thread-unread records: $failedIds',
          );
        }
      }

      // Clear readAt for all pushed threads
      final allIds = readActivities.map((a) => a.id.toBytes()).toList();
      await (Store.get.update(Store.get.threads)
            ..where((t) => t.id.isIn(allIds)))
          .write(const ThreadsCompanion(readAt: Value(null)));
    } catch (e) {
      if (e is ApiException && Store._isPermanentError(e)) {
        // Permanent error — clear readAt to stop retrying
        log.warning(
          'Permanent error pushing thread-unread, '
          'clearing ${readActivities.length} records: $e',
        );
        final allIds = readActivities.map((a) => a.id.toBytes()).toList();
        await (Store.get.update(Store.get.threads)
              ..where((t) => t.id.isIn(allIds)))
            .write(const ThreadsCompanion(readAt: Value(null)));
      } else {
        // Transient error — readAt stays, retry on next push cycle
        log.warning('Failed to push thread-unread changes: $e');
        rethrow;
      }
    }

    return success;
  }

  /// Splits [search] on whitespace, strips FTS5 special chars, and keeps
  /// words ≥ 2 chars. Shared by the FTS branch and the contact-name match
  /// resolution so both apply the same gating and word ordering.
  @visibleForTesting
  static List<String> sanitizeSearchWords(String? search) =>
      _sanitizeSearchWords(search);

  static List<String> _sanitizeSearchWords(String? search) {
    if (search == null || search.isEmpty) return const [];
    return search
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map(
          (word) => word.replaceAll(RegExp(r'''['"*()/:+\-^~{}\[\]@#]'''), ''),
        )
        .where((word) => word.length >= 2)
        .toList();
  }

  /// Builds an FTS5 MATCH expression from sanitized search words. Each
  /// word is further split into alphanumeric-only tokens (matching the
  /// `ascii` tokenizer used by `thread_fts` / `note_fts`) and emitted as
  /// a prefix term, joined by spaces (implicit AND). Returns an empty
  /// string when no token survives — callers should drop the FTS branch
  /// in that case rather than emit an invalid `MATCH ''` clause.
  @visibleForTesting
  static String ftsQueryFromWords(List<String> sanitizedWords) =>
      _ftsQueryFromWords(sanitizedWords);

  static String _ftsQueryFromWords(List<String> sanitizedWords) {
    return sanitizedWords
        .expand((word) => word.split(RegExp(r'[^A-Za-z0-9]+')))
        .where((token) => token.length >= 2)
        .map((token) => '$token*')
        .join(' ');
  }

  /// Resolves contact-name matches for each sanitized search word. Returns
  /// null if there are no usable words (so the search clause itself will be
  /// skipped). Each returned sublist is the set of actor UUID strings whose
  /// name has a word starting with the corresponding search word, or whose
  /// email starts with it. Empty sublists are kept so positions stay aligned
  /// with the sanitized words list — the consumer treats any-empty as a
  /// signal to drop the contacts branch.
  static Future<List<List<String>>?> _resolveContactIdMatches(
    String? search,
  ) async {
    final words = _sanitizeSearchWords(search);
    if (words.isEmpty) return null;
    final result = <List<String>>[];
    for (final word in words) {
      result.add(await Actor.idsMatchingWordPrefix(word));
    }
    return result;
  }

  static Future<List<Thread>> get({
    DateRange? range,
    DateTime? eventsActiveAt,
    ThreadId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool? draft = false,
    String? search,
    bool self = true,
    ThreadOrder order = ThreadOrder.sorted,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    bool eventsOnly = false,
    int? limit,
  }) async {
    return await _get(
      range: range,
      eventsActiveAt: eventsActiveAt,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      order: order,
      search: search,
      self: self,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      includeAllFutureEvents: includeAllFutureEvents,
      includeUnscheduled: includeUnscheduled,
      eventsOnly: eventsOnly,
      limit: limit,
    );
  }

  static Stream<ThreadWatchResult> watch({
    DateRange? range,
    DateTime? eventsActiveAt,
    DateRange? occurrenceRange,
    ThreadId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool? draft = false,
    String? search,
    bool self = true,
    ThreadOrder order = ThreadOrder.sorted,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    bool linkScheduledOnly = false,
    bool todoOnly = false,
    bool eventsOnly = false,
    int? limit,
    int? offset,
  }) {
    // Activity-feed fast path: when the caller wants the reverse-chronological
    // feed with a LIMIT (and no range / non-feed flags), use the two-step
    // ID-first query so LIMIT applies to distinct threads instead of the
    // 14×-multiplied join product. See [_watchActivityFeedIds].
    final useFeedFastPath =
        order == ThreadOrder.reverse &&
        limit != null &&
        range == null &&
        id == null &&
        !linkScheduledOnly &&
        !todoOnly &&
        !eventsOnly;

    // Resolve contact-name matches once per search before opening the
    // change-driven stream. New search text triggers a new subscription,
    // so we don't need to re-resolve when contacts are inserted/updated.
    return Stream.fromFuture(_resolveContactIdMatches(search)).asyncExpand((
      contactIdMatchesPerWord,
    ) {
      if (useFeedFastPath) {
        return _watchActivityFeedIds(
          priorityId: priorityId,
          priorityPath: priorityPath,
          archived: archived,
          draft: draft ?? false,
          search: search,
          contactIdMatchesPerWord: contactIdMatchesPerWord,
          filter: filter,
          reactionFilter: reactionFilter,
          iconFilter: iconFilter,
          limit: limit,
          offset: offset ?? 0,
        ).asyncMap((idRows) async {
          if (!Store.isAvailable) {
            return (threads: <Thread>[], rawRowCount: 0, feedTailCursor: null);
          }
          if (idRows.isEmpty) {
            return (threads: <Thread>[], rawRowCount: 0, feedTailCursor: null);
          }
          final ids = idRows.map((r) => r.id).toList();
          final detailRows = await _hydrateActivityFeedRows(ids);
          final threads = await _mapResultsToThreads(
            detailRows,
            archived: archived,
            range: occurrenceRange,
          );
          // Restore the Phase-1 ordering: _mapResultsToThreads groups by id
          // and doesn't preserve the input order, and the Phase-2 hydration
          // query has no ORDER BY (intentional — the order came from Phase 1).
          final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
          threads.sort(
            (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
              orderByIndex[y.id] ?? 1 << 30,
            ),
          );
          // Expose the SQL-computed cursor of the tail row. The bloc's
          // [fetchMoreActivityFeedItems] uses this to keyset-paginate
          // beyond the head. Deriving the cursor in Dart from
          // [Thread.activityAt] doesn't match the SQL formula in all
          // cases (Dart's activityAt is a MAX over fields; SQL's
          // activity_at uses COALESCE-then-MAX for the first triple).
          final tail = idRows.last;
          return (
            threads: threads,
            rawRowCount: threads.length,
            feedTailCursor: (
              unreadSort: tail.unreadSort,
              activityAt: tail.activityAt,
              id: tail.id,
            ),
          );
        });
      }

      return _getQuery(
        range: range,
        eventsActiveAt: eventsActiveAt,
        id: id,
        priorityId: priorityId,
        priorityPath: priorityPath,
        archived: archived,
        draft: draft,
        order: order,
        search: search,
        contactIdMatchesPerWord: contactIdMatchesPerWord,
        self: self,
        filter: filter,
        reactionFilter: reactionFilter,
        iconFilter: iconFilter,
        includeAllFutureEvents: includeAllFutureEvents,
        includeUnscheduled: linkScheduledOnly ? false : includeUnscheduled,
        linkScheduledOnly: linkScheduledOnly,
        todoOnly: todoOnly,
        eventsOnly: eventsOnly,
        limit: limit,
        offset: offset,
      ).watch().asyncMap((results) async {
        if (!Store.isAvailable) {
          return (threads: <Thread>[], rawRowCount: 0, feedTailCursor: null);
        }
        final threads = await _mapResultsToThreads(
          results,
          archived: archived,
          range: occurrenceRange ?? range,
        );
        // Re-sort activity feed for precise recurring event ordering
        if (order == ThreadOrder.reverse) {
          threads.sort((a, b) {
            if (a.unread != b.unread) {
              return a.unread ? -1 : 1;
            }
            return b.activityAt.compareTo(a.activityAt);
          });
        }
        return (
          threads: threads,
          rawRowCount: results.length,
          feedTailCursor: null,
        );
      });
    });
  }

  /// Watch threads that are children of active thread associations.
  /// Uses the same table aliases as [_getQuery] so results can be processed
  /// by [_mapResultsToThreads].
  static Stream<List<Thread>> watchAssociatedThreads() {
    final a = Store.get.alias(Store.get.threads, 'a');
    final sched = Store.get.alias(Store.get.schedules, 'sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');
    final tags = Store.get.alias(Store.get.threadTags, 'tags');
    final ta = Store.get.threadAssociations;

    final query = Store.get.select(a).join([
      // INNER JOIN thread_associations to select only associated children
      innerJoin(ta, ta.childThreadId.equalsExp(a.id) & ta.archivedAt.isNull()),
      // Same joins as _getQuery so _mapResultsToThreads works. Per-user
      // state (active / task / to_read / urgent / state_order / state_on
      // / state_at / read_at) lives on the thread row itself, so no
      // per-user schedule join is needed.
      leftOuterJoin(
        sched,
        sched.threadId.equalsExp(a.id) & sched.linkId.isNull(),
      ),
      leftOuterJoin(linkTable, linkTable.threadId.equalsExp(a.id)),
      leftOuterJoin(linkSched, linkSched.linkId.equalsExp(linkTable.id)),
      leftOuterJoin(
        tags,
        (tags.id.equalsExp(a.id) | (tags.id.isNull() & a.id.isNull())) &
            (tags.occurrence.equalsExp(sched.occurrence) |
                (tags.occurrence.equals('') & sched.occurrence.isNull())),
      ),
    ]);

    // Only non-archived, non-draft threads
    query.where(a.archivedAt.isNull());
    query.where(a.draft.equals(false));

    return query.watch().asyncMap((results) async {
      if (!Store.isAvailable) return <Thread>[];
      return _mapResultsToThreads(results, range: null);
    });
  }

  static Future<Thread> getOne(ThreadId id) async {
    final threads = await _get(
      id: id,
      archived: null,
      draft: null,
      order: ThreadOrder.sorted,
    );
    if (threads.isEmpty) {
      log.warning("Thread not found: $id");
      throw Exception('Thread not found');
    }
    return threads.first;
  }

  static Stream<Thread> watchOne(ThreadId id) {
    return _getQuery(
          id: id,
          archived: null,
          draft: null,
          order: ThreadOrder.sorted,
        )
        .watch()
        .asyncMap((results) async {
          if (!Store.isAvailable) return null;
          final threads = await _mapResultsToThreads(results, range: null);
          if (threads.isEmpty) {
            throw Exception('Thread not found');
          }
          return threads.first;
        })
        .where((t) => t != null)
        .cast<Thread>();
  }

  /// Get the most recent draft thread filed at any priority on the same
  /// chain as [priority] — that is, an ancestor, [priority] itself, or any
  /// descendant. This makes a draft "sticky" within a branch: the user can
  /// navigate up or down inside Work and keep editing the same draft, while
  /// switching to a sibling branch (e.g. Personal) yields a fresh draft.
  static Future<Thread?> getDraftInChain(Priority priority) async {
    final drafts = await _get(
      draft: true,
      archived: false,
      order: ThreadOrder.sorted,
    );
    if (drafts.isEmpty) return null;
    final pathStr = priority.path.value;
    final chainDrafts = drafts.where((d) {
      final dp = d.priority.path.value;
      return dp == pathStr ||
          pathStr.startsWith('$dp.') || // ancestor
          dp.startsWith('$pathStr.'); // descendant
    }).toList();
    if (chainDrafts.isEmpty) return null;
    chainDrafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chainDrafts.first;
  }

  /// Watch all tags present in threads. When [priorityPath] is provided the
  /// counts are scoped to that priority and its descendants; when null
  /// (the default) the counts are global across every priority — header
  /// search is global, so the filter chips it offers must be too.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForPriority([Path? priorityPath]) {
    final at = Store.get.threadTags;
    final a = Store.get.threads;
    final p = Store.get.priorities;

    final now = Time.now();
    final today = Date.today().toString();

    // Each query inner-joins the thread to its priority only when scoping to
    // one (priorityPath != null); a fresh Join is built per statement.

    // Query for stored tags from activity_tags table
    final tagsQuery = Store.get.select(at).join([
      innerJoin(a, a.id.equalsExp(at.id)),
      if (priorityPath != null)
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
    ]);

    tagsQuery.where(a.archivedAt.isNull());

    // COUNT query for Tag.todo
    final s = Store.get.schedules;
    final nowQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    nowQuery.join([
      if (priorityPath != null)
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
      leftOuterJoin(s, s.threadId.equalsExp(a.id) & s.linkId.isNull()),
    ]);
    nowQuery.where(
      a.archivedAt.isNull() &
          (
          // Date-based scheduling: startOn <= today
          (s.startOn.isSmallerOrEqualValue(today) & s.startAt.isNull()) |
              // DateTime-based scheduling: startAt <= now AND endAt >= now
              (s.startAt.isSmallerOrEqualValue(now) &
                  (s.endAt.isNull() | s.endAt.isBiggerOrEqualValue(now))) |
              // Per-user todo: thread has the active flag set.
              a.active.equals(true)),
    );
    final nowCountStream = nowQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.archived
    final archivedQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    archivedQuery.join([
      if (priorityPath != null)
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
    ]);
    archivedQuery.where(a.archivedAt.isNotNull());
    final archivedCountStream = archivedQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for archived priorities
    final archivedPriorityQuery = Store.get.selectOnly(p)..addColumns([p.id]);
    archivedPriorityQuery.where(
      priorityPath != null
          ? p.path.equalsValue(priorityPath) & p.archivedAt.isNotNull()
          : p.archivedAt.isNotNull(),
    );
    final archivedPriorityCountStream = archivedPriorityQuery.watch().map(
      (rows) => rows.length,
    );

    // COUNT query for Tag.unread
    final unreadQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    unreadQuery.join([
      if (priorityPath != null)
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
    ]);
    unreadQuery.where(
      a.archivedAt.isNull() &
          a.draft.equals(false) &
          a.unread.equals(true) &
          a.readAt.isNull(),
    );
    final unreadCountStream = unreadQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    return Rx.combineLatest5(
      tagsQuery.watch(),
      nowCountStream,
      archivedCountStream,
      unreadCountStream,
      archivedPriorityCountStream,
      (rows, nowCount, archivedCount, unreadCount, archivedPriorityCount) {
        final Map<Tag, int> tagCounts = {};

        // Count stored tags
        final Map<Tag, Set<ThreadId>> storedTagCounts = {};
        for (final row in rows) {
          final activityTagsRow = row.readTable(at);
          final activityId = activityTagsRow.id;
          final tags = activityTagsRow.tags;

          if (tags != null) {
            for (final tag in tags.keys) {
              storedTagCounts.putIfAbsent(tag, () => {}).add(activityId);
            }
          }
        }

        // Add stored tag counts
        for (final entry in storedTagCounts.entries) {
          tagCounts[entry.key] = entry.value.length;
        }

        // Add computed tag counts
        if (nowCount > 0) tagCounts[Tag.todo] = nowCount;
        final totalArchived = archivedCount + archivedPriorityCount;
        if (totalArchived > 0) tagCounts[Tag.archived] = totalArchived;
        if (unreadCount > 0) tagCounts[Tag.unread] = unreadCount;

        // Convert to list of (Tag, count) and sort by count descending
        final result = tagCounts.entries.map((e) => (e.key, e.value)).toList()
          ..sort((a, b) => b.$2.compareTo(a.$2));

        return result;
      },
    );
  }

  /// Watch all reactions present on threads. When [priorityPath] is provided
  /// the counts are scoped to that priority and its descendants; when null
  /// (the default) the counts are global across every priority. Returns a
  /// stream of (Reaction, count) tuples sorted by thread count descending.
  /// Scoped to thread-level reactions only — note-level reaction filtering is
  /// handled by [Note.watch].
  static Stream<List<(Reaction, int)>> watchReactionsForPriority([
    Path? priorityPath,
  ]) {
    final tr = Store.get.threadReactions;
    final a = Store.get.threads;
    final p = Store.get.priorities;

    final query = Store.get.select(tr).join([
      innerJoin(a, a.id.equalsExp(tr.id) & a.archivedAt.isNull()),
      if (priorityPath != null)
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
        ),
    ]);

    return query.watch().map((rows) {
      final counts = <Reaction, Set<ThreadId>>{};
      for (final row in rows) {
        final reactions = row.readTable(tr).reactions;
        if (reactions == null) continue;
        final threadId = row.readTable(a).id;
        for (final emoji in reactions.keys) {
          counts.putIfAbsent(emoji, () => <ThreadId>{}).add(threadId);
        }
      }
      final result = counts.entries.map((e) => (e.key, e.value.length)).toList()
        ..sort((a, b) => b.$2.compareTo(a.$2));
      return result;
    });
  }

  /// Watches icon value counts for non-archived threads. When [priorityPath]
  /// is provided the counts are scoped to that priority and its descendants;
  /// when null (the default) the counts are global across every priority.
  static Stream<List<(String, int)>> watchIconCountsForPriority([
    Path? priorityPath,
  ]) {
    final a = Store.get.threads;
    final p = Store.get.priorities;

    final query = Store.get.selectOnly(a)
      ..addColumns([a.icon, a.id.count()])
      ..join([
        if (priorityPath != null)
          innerJoin(
            p,
            p.id.equalsExp(a.priorityId) & p.path.equalsValue(priorityPath),
          ),
      ])
      ..where(a.archivedAt.isNull() & a.draft.equals(false))
      ..groupBy([a.icon]);

    return query.watch().map((rows) {
      // Collapse all pasted-link threads (favicon-URL icons + the literal
      // 'link' icon) under a single synthetic 'link' bucket so the filter
      // modal shows one "Link" chip instead of one per favicon URL.
      var linkCount = 0;
      final collapsed = <(String, int)>[];
      for (final row in rows) {
        final icon = row.read(a.icon);
        final count = row.read(a.id.count());
        if (icon == null || count == null) continue;
        if (icon == 'link' || icon.startsWith('http')) {
          linkCount += count;
          continue;
        }
        // Drop twist:N icons for twists that aren't installed locally —
        // they render as a generic "Twist" chip with no way to tell them
        // apart, so each uninstalled twist would add a duplicate row.
        if (icon.startsWith('twist:')) {
          final twistId = BigInt.tryParse(icon.substring(6));
          if (twistId == null || TwistInstance.findByTwistId(twistId) == null) {
            continue;
          }
        }
        collapsed.add((icon, count));
      }
      if (linkCount > 0) {
        collapsed.add(('link', linkCount));
      }
      return collapsed;
    });
  }

  static Future<List<Thread>> _get({
    DateRange? range,
    DateTime? eventsActiveAt,
    bool strictRange = false,

    /* Selectors */
    ThreadId? id,
    PriorityId? priorityId,
    Path? priorityPath,

    /* Filters */
    bool self = true,
    bool? archived = false,
    bool? draft = false,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    bool eventsOnly = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,

    /* Sorting */
    ThreadOrder order = ThreadOrder.sorted,

    /* Pagination */
    int? limit,
    int? offset,

    /* Augmentation */
    bool getParent = true,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final query = _getQuery(
      range: range,
      eventsActiveAt: eventsActiveAt,
      strictRange: strictRange,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      self: self,
      archived: archived,
      draft: draft,
      includeAllFutureEvents: includeAllFutureEvents,
      includeUnscheduled: includeUnscheduled,
      eventsOnly: eventsOnly,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      order: order,
      limit: limit,
      offset: offset,
      getParent: getParent,
    );

    final results = await query.get();
    return _mapResultsToThreads(results, archived: archived, range: range);
  }

  static JoinedSelectStatement<HasResultSet, dynamic> _getQuery({
    DateRange? range,
    // Only include activities that start within the range
    bool strictRange = false,

    /// When set, overrides the lower bound used for the datetime-based
    /// **event** range branches (shared schedule, link schedule) so the
    /// query returns events still in progress at this moment plus
    /// everything after, instead of also surfacing events that ended
    /// earlier in the day. Per-user / todo branches keep using
    /// `range.start` so overdue and "anytime today" todos stay visible.
    /// Used by the agenda to keep its pagination window aligned with
    /// what's actually rendered.
    DateTime? eventsActiveAt,

    /* Selectors */
    ThreadId? id,
    PriorityId? priorityId,
    Path? priorityPath,

    /* Filters */
    bool self = true,
    bool? archived = false,
    bool? draft = false,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    bool linkScheduledOnly = false,

    /// SQL form of [Thread.todo]: an active per-user schedule with at least
    /// one date set. Lets the activity feed's todo stream skip the
    /// `includeUnscheduled: false` over-fetch (which admits any thread
    /// joined to ANY schedule, including shared/link-only events) followed
    /// by a Dart-side `.where((t) => t.todo)` discard. Mirrors the
    /// `activeTodo` sub-expression below at lines ~1582-1586.
    bool todoOnly = false,

    /// Drops every WHERE branch that admits a thread on the strength of
    /// its **per-user schedule** alone — `activeTodo`, the date-range
    /// user-schedule branches, and the `unscheduled` branch. The query
    /// then only returns threads with a shared or link schedule (the
    /// kinds of rows agendas render with a time label). Pairs with a
    /// sibling `todoOnly: true` watch when the caller wants events and
    /// todos in separate streams so the LIMIT on events doesn't fight
    /// with overdue / sentinel-dated todos for the same row budget.
    bool eventsOnly = false,
    String? search,

    /// Per-search-word lists of actor UUID strings whose name has a word
    /// starting with that search word (resolved via [Actor.idsMatchingWordPrefix]).
    /// When non-null and aligned with the sanitized search words, the search
    /// clause also matches threads whose `contacts` column includes one of
    /// the listed actors per word (ANDed across words). Resolved by
    /// [_resolveContactIdMatches] before the query is built.
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,

    /* Sorting */
    ThreadOrder order = ThreadOrder.sorted,

    /* Pagination */
    int? limit,
    int? offset,

    /* Augmentation */
    bool getParent = true, // Deprecated, kept for compatibility
  }) {
    // Create a copy of filter to avoid mutating the original
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;
    if (mutableFilter?.remove(Tag.archived) == true) {
      archived = null;
    }

    final doTodo = mutableFilter?.remove(Tag.todo) == true;
    final filterUnread = mutableFilter?.remove(Tag.unread) == true;

    final a = Store.get.alias(Store.get.threads, 'a');
    final sched = Store.get.alias(Store.get.schedules, 'sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');
    final startingQuery = Store.get.select(a);

    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (priorityId != null) {
      startingQuery.where((t) => t.priorityId.equalsValue(priorityId));
    }

    var query = startingQuery.join([
      // Shared schedule (event timing, visible to all priority members).
      // Per-user state — active / task / to_read / urgent / state_order /
      // state_on / state_at / read_at — now lives directly on the thread
      // row (a.*), so no per-user schedule join is needed.
      leftOuterJoin(
        sched,
        sched.threadId.equalsExp(a.id) & sched.linkId.isNull(),
      ),
      // Links for this thread, then their shared schedules
      leftOuterJoin(linkTable, linkTable.threadId.equalsExp(a.id)),
      leftOuterJoin(linkSched, linkSched.linkId.equalsExp(linkTable.id)),
    ]);
    final now = Time.now();

    // Add priority filtering:
    // 1. Filter by priorityPath if provided
    // 2. Exclude activities with archived priorities when archived == false
    final p = Store.get.alias(Store.get.priorities, 'p');
    if (linkScheduledOnly) {
      // linkScheduledOnly: fetch link-scheduled threads from all priorities.
      // Use LEFT JOIN for priority data hydration (needed by _mapResultsToThreads)
      // but do not filter by path.
      Expression<bool> joinCondition = p.id.equalsExp(a.priorityId);
      query = query.join([leftOuterJoin(p, joinCondition)]);

      // Require a link schedule to exist
      query.where(
        linkSched.startAt.isNotNull() | linkSched.startOn.isNotNull(),
      );
    } else if (priorityPath != null) {
      // Flat priority model: a priority shows only what's filed directly
      // in it. The path equality is the join key (combined with the id
      // match so each thread's filed priority must equal this priority).
      Expression<bool> pathCondition = p.path.equalsValue(priorityPath);

      if (includeAllFutureEvents) {
        // Per-user state has no end-at (no recurrence / end columns), so
        // a future per-user todo with no shared schedule is matched by the
        // active-todo branch in the range block below, not here.
        pathCondition =
            pathCondition |
            sched.endAt.isBiggerOrEqualValue(now) |
            linkSched.endAt.isBiggerOrEqualValue(now);
      }

      Expression<bool> joinCondition =
          p.id.equalsExp(a.priorityId) & pathCondition;

      query = query.join([innerJoin(p, joinCondition)]);
    }

    if (doTodo) {
      query.where(
        (
        // Shared date-based scheduling: startOn <= today
        (sched.startOn.isSmallerOrEqualValue(Date.today().toString()) &
                sched.startAt.isNull()) |
            // Shared datetime-based scheduling: startAt <= now AND endAt >= now
            (sched.startAt.isSmallerOrEqualValue(now) &
                (sched.endAt.isNull() |
                    sched.endAt.isBiggerOrEqualValue(now))) |
            // Per-user todo: thread has the active flag set.
            a.active.equals(true) |
            // Link schedule date-based: startOn <= today
            (linkSched.startOn.isSmallerOrEqualValue(Date.today().toString()) &
                linkSched.startAt.isNull()) |
            // Link schedule datetime-based: startAt <= now AND endAt >= now
            (linkSched.startAt.isSmallerOrEqualValue(now) &
                (linkSched.endAt.isNull() |
                    linkSched.endAt.isBiggerOrEqualValue(now)))),
      );
    }
    if (filterUnread) {
      query.where(a.unread.equals(true) & a.readAt.isNull());
    }
    if (todoOnly) {
      // SQL translation of [Thread.isActive]: just `active == true`.
      // Reading or reordering doesn't remove from Doing — only flipping
      // `active` off (via `todo: false`) does.
      query.where(a.active.equals(true));
    }
    if (archived != null) {
      query.where(archived ? a.archivedAt.isNotNull() : a.archivedAt.isNull());
    }
    if (draft != null) {
      query.where(a.draft.equals(draft));
    }
    if (search?.isNotEmpty == true) {
      // Split and sanitize search words once for both FTS5 and LIKE matching
      final sanitizedWords = _sanitizeSearchWords(search);

      // FTS5 query syntax rejects '.' (and other punctuation) inside a
      // bareword with `fts5: syntax error near "."`, so passing 'cal.com*'
      // would throw and abort the entire query. Pre-split each sanitized
      // word into pure-alphanumeric tokens (matching the ascii tokenizer's
      // separator rules) and prefix-match each one — 'cal.com' becomes
      // 'cal* com*' (implicit AND). The link-LIKE branch below still uses
      // the un-split sanitized words so substring matches like
      // `source_url LIKE '%cal.com%'` continue to work.
      final ftsWords = _ftsQueryFromWords(sanitizedWords);

      if (sanitizedWords.isNotEmpty) {
        // Each word must appear in either link title or source_url
        final linkConditions = sanitizedWords
            .map(
              (word) => "(title LIKE '%$word%' OR source_url LIKE '%$word%')",
            )
            .join(' AND ');

        // Optional contacts branch: match threads whose `contacts` column
        // includes at least one resolved actor per search word (ANDed
        // across words). Only enabled when every word resolved to ≥1
        // matching actor — otherwise the AND chain would be unsatisfiable
        // and we skip the branch entirely.
        String? contactBranch;
        if (contactIdMatchesPerWord != null &&
            contactIdMatchesPerWord.length == sanitizedWords.length &&
            contactIdMatchesPerWord.every((ids) => ids.isNotEmpty)) {
          final clauses = <String>[];
          for (final ids in contactIdMatchesPerWord) {
            // UUIDs are validated when fetched from the actors table, so
            // direct interpolation is safe.
            final orParts = ids
                .map(
                  (id) =>
                      "(',' || COALESCE(a.contacts, '') || ',') LIKE '%,$id,%'",
                )
                .join(' OR ');
            clauses.add('($orParts)');
          }
          contactBranch = clauses.join(' AND ');
        }

        // FTS branches are skipped when no usable token survives splitting
        // (e.g. 'a.b' → 'a','b' are both <2 chars). The link-LIKE branch
        // still applies, so URL searches like '?.?' that have no FTS terms
        // can still match through source_url.
        final ftsBranch = ftsWords.isNotEmpty
            ? '''SELECT thread_id FROM thread_fts WHERE thread_fts MATCH '$ftsWords'
              UNION ALL
              SELECT thread_id FROM note_fts WHERE note_fts MATCH '$ftsWords'
              UNION ALL
              '''
            : '';

        // Drive the search from the small match-set instead of evaluating
        // correlated EXISTS per thread. With OR'd correlated EXISTS the
        // planner falls back to SCAN threads × N subqueries (FTS scan per
        // row, full links scan per row with leading-wildcard LIKE), which
        // takes seconds on real data. A `thread.id IN (UNION ALL …)` form
        // lets SQLite execute each match source once and look threads up
        // by primary key.
        query.where(
          CustomExpression<bool>('''
            a.id IN (
              ${ftsBranch}SELECT thread_id FROM links WHERE thread_id IS NOT NULL AND $linkConditions
            )
            ${contactBranch != null ? 'OR ($contactBranch)' : ''}
          '''),
        );
      }
    }
    if (iconFilter != null && iconFilter.isNotEmpty) {
      // 'link' is the synthetic bucket for pasted-link threads — it matches
      // both the literal 'link' icon and any favicon-URL icon. See
      // watchIconCountsForPriority for the collapsing logic. Any URL-style
      // value (legacy state from before the collapse) is treated the same.
      final includesLink = iconFilter.any(
        (v) => v == 'link' || v.startsWith('http'),
      );
      final others = iconFilter
          .where((v) => v != 'link' && !v.startsWith('http'))
          .toList();
      Expression<bool>? predicate;
      if (includesLink) {
        predicate = a.icon.equals('link') | a.icon.like('http%');
      }
      if (others.isNotEmpty) {
        final othersPredicate = a.icon.isIn(others);
        predicate = predicate == null
            ? othersPredicate
            : predicate | othersPredicate;
      }
      if (predicate != null) {
        query.where(predicate);
      }
    }
    if (self == false) {
      if (id != null) {
        query.where(a.id.equalsValue(id).not());
      }
    }

    if (range != null) {
      final rangeStart = range.start?.toDateTime();
      final rangeEnd = range.end?.toDateTime();
      Expression<bool> condition = Constant(false);

      // Unscheduled activities - included regardless of date range when requested.
      // Must check both shared schedule and per-user state have no dates.
      // Excluded for agenda queries where unscheduled non-todo items would
      // consume the LIMIT and then be filtered out as past dates.
      if (includeUnscheduled && !eventsOnly) {
        Expression<bool> unscheduled =
            sched.startOn.isNull() &
            sched.startAt.isNull() &
            a.stateOn.isNull() &
            a.stateAt.isNull();
        condition = condition | unscheduled;
      }

      // Active todo: always include threads with the active flag set.
      // Skip for linkScheduledOnly — we only want threads by their link
      // schedule, not by their per-user state.
      // Skip for eventsOnly — caller is running a separate todoOnly watch.
      if (!linkScheduledOnly && !eventsOnly) {
        condition = condition | a.active.equals(true);
      }

      // Activity is scheduled within the range (Date-based)
      if (range.start != null || range.end != null) {
        // Shared schedule date-based
        Expression<bool> dateScheduled = sched.startOn.isNotNull();
        if (range.start != null) {
          if (strictRange) {
            dateScheduled =
                dateScheduled &
                sched.startOn.isBiggerOrEqualValue(range.start!.toString());
          } else {
            dateScheduled =
                dateScheduled &
                (sched.endOn.isNull() |
                    sched.endOn.isBiggerOrEqualValue(range.start!.toString()));
          }
        }
        if (range.end != null) {
          dateScheduled =
              dateScheduled &
              sched.startOn.isSmallerThanValue(range.end!.toString());
        }
        condition = condition | dateScheduled;

        // Per-user state date-based. Skipped for eventsOnly so the
        // caller's sibling todoOnly watch is the sole source for these.
        // Per-user state has no end_on column (no recurrence / end), so
        // the open-range fallback in `strictRange == false` just matches
        // on start.
        if (!eventsOnly) {
          Expression<bool> userDateScheduled = a.stateOn.isNotNull();
          if (range.start != null && strictRange) {
            userDateScheduled =
                userDateScheduled &
                a.stateOn.isBiggerOrEqualValue(range.start!.toString());
          }
          if (range.end != null) {
            userDateScheduled =
                userDateScheduled &
                a.stateOn.isSmallerThanValue(range.end!.toString());
          }
          condition = condition | userDateScheduled;
        }
      }

      // Activity is scheduled within the range (DateTime-based)
      // Shared schedule
      final eventRangeStart = eventsActiveAt ?? rangeStart;
      Expression<bool> dateTimeScheduled = sched.startAt.isNotNull();
      if (eventRangeStart != null) {
        if (strictRange) {
          dateTimeScheduled =
              dateTimeScheduled &
              sched.startAt.isBiggerOrEqualValue(eventRangeStart);
        } else {
          dateTimeScheduled =
              dateTimeScheduled &
              (sched.endAt.isNull() |
                  sched.endAt.isBiggerOrEqualValue(eventRangeStart));
        }
      }
      if (rangeEnd != null) {
        dateTimeScheduled =
            dateTimeScheduled & sched.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | dateTimeScheduled;

      // Per-user state datetime-based. Skipped for eventsOnly (see
      // userDateScheduled). Per-user state has no end_at column, so the
      // open-range fallback in `strictRange == false` just matches on
      // start.
      if (!eventsOnly) {
        Expression<bool> userDateTimeScheduled = a.stateAt.isNotNull();
        if (rangeStart != null && strictRange) {
          userDateTimeScheduled =
              userDateTimeScheduled &
              a.stateAt.isBiggerOrEqualValue(rangeStart);
        }
        if (rangeEnd != null) {
          userDateTimeScheduled =
              userDateTimeScheduled & a.stateAt.isSmallerThanValue(rangeEnd);
        }
        condition = condition | userDateTimeScheduled;
      }

      // Link schedule date-based
      if (range.start != null || range.end != null) {
        Expression<bool> linkDateScheduled = linkSched.startOn.isNotNull();
        if (range.start != null) {
          if (strictRange) {
            linkDateScheduled =
                linkDateScheduled &
                linkSched.startOn.isBiggerOrEqualValue(range.start!.toString());
          } else {
            linkDateScheduled =
                linkDateScheduled &
                (linkSched.endOn.isNull() |
                    linkSched.endOn.isBiggerOrEqualValue(
                      range.start!.toString(),
                    ));
          }
        }
        if (range.end != null) {
          linkDateScheduled =
              linkDateScheduled &
              linkSched.startOn.isSmallerThanValue(range.end!.toString());
        }
        condition = condition | linkDateScheduled;
      }

      // Link schedule datetime-based
      Expression<bool> linkDateTimeScheduled = linkSched.startAt.isNotNull();
      if (eventRangeStart != null) {
        if (strictRange) {
          linkDateTimeScheduled =
              linkDateTimeScheduled &
              linkSched.startAt.isBiggerOrEqualValue(eventRangeStart);
        } else {
          linkDateTimeScheduled =
              linkDateTimeScheduled &
              (linkSched.endAt.isNull() |
                  linkSched.endAt.isBiggerOrEqualValue(eventRangeStart));
        }
      }
      if (rangeEnd != null) {
        linkDateTimeScheduled =
            linkDateTimeScheduled &
            linkSched.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | linkDateTimeScheduled;

      query.where(condition);
    }

    if (limit != null) {
      query.limit(limit, offset: offset);
    }

    switch (order) {
      case ThreadOrder.sorted:
        // Pagination rank: hard-scheduled rows (shared/link schedule with a
        // date) come before user-only todos so a flood of overdue or
        // sentinel-dated todos can't push real events past `limit`. Visual
        // ordering in the agenda is driven by `agendaAt` in
        // [AgendaBuilder.build], not this clause — the discriminator
        // only governs which rows survive pagination when the result set is
        // larger than the limit.
        final hasHardSchedule = CaseWhenExpression<int>(
          cases: [
            CaseWhen(sched.startAt.isNotNull(), then: Constant(0)),
            CaseWhen(sched.startOn.isNotNull(), then: Constant(0)),
            CaseWhen(linkSched.startAt.isNotNull(), then: Constant(0)),
            CaseWhen(linkSched.startOn.isNotNull(), then: Constant(0)),
          ],
          orElse: Constant(1),
        );
        // Todo list: schedule-based sorting (check shared then per-user then link)
        final todoSort = CaseWhenExpression(
          cases: [
            CaseWhen(sched.startAt.isNotNull(), then: sched.startAt),
            CaseWhen(sched.startOn.isNotNull(), then: sched.startOn),
            CaseWhen(a.stateAt.isNotNull(), then: a.stateAt),
            CaseWhen(a.stateOn.isNotNull(), then: a.stateOn),
            CaseWhen(linkSched.startAt.isNotNull(), then: linkSched.startAt),
            CaseWhen(linkSched.startOn.isNotNull(), then: linkSched.startOn),
          ],
          orElse: Constant(DateTime.utc(0)),
        );
        query.orderBy([
          OrderingTerm.asc(hasHardSchedule),
          OrderingTerm.asc(todoSort),
          OrderingTerm.asc(a.stateOrder),
        ]);
        break;
      case ThreadOrder.reverse:
        // Activity feed: GREATEST(lastNoteSourceCreatedAt, linkSourceCreatedAt, bumpedAt, pastScheduleEnd)
        // Falls back to createdAt only when all are null.
        final epoch = Constant(DateTime.fromMillisecondsSinceEpoch(0));
        final now = Time.now();
        final schedEnd = CaseWhenExpression(
          cases: [
            CaseWhen(
              sched.endAt.isNotNull() &
                  sched.occurrence.isNull() &
                  sched.endAt.isSmallerOrEqualValue(now),
              then: sched.endAt,
            ),
          ],
          orElse: epoch,
        );
        final feedSort = FunctionCallExpression('MAX', [
          coalesce([
            a.lastNoteSourceCreatedAt,
            linkTable.sourceCreatedAt,
            a.createdAt,
          ]),
          coalesce([a.bumpedAt, epoch]),
          schedEnd,
        ]);

        final unreadSort = a.unread.equals(true) & a.readAt.isNull();

        query.orderBy([
          OrderingTerm.desc(unreadSort),
          OrderingTerm.desc(feedSort),
        ]);
        break;
    }

    // Add join for tags (sched already joined above)
    final tags = Store.get.alias(Store.get.threadTags, 'tags');
    final reactions = Store.get.alias(Store.get.threadReactions, 'reactions');
    final hasReactionFilter =
        reactionFilter != null && reactionFilter.isNotEmpty;

    query = query.join([
      leftOuterJoin(
        tags,
        (tags.id.equalsExp(a.id) | (tags.id.isNull() & a.id.isNull())) &
            (tags.occurrence.equalsExp(sched.occurrence) |
                (tags.occurrence.equals('') & sched.occurrence.isNull())),
      ),
      // Only join reactions when filtering — keeps the unfiltered path cheap.
      if (hasReactionFilter)
        leftOuterJoin(
          reactions,
          reactions.id.equalsExp(a.id) &
              (reactions.occurrence.equalsExp(sched.occurrence) |
                  (reactions.occurrence.equals('') &
                      sched.occurrence.isNull())),
        ),
    ]);

    // Add tag filtering if filter list is provided
    // This must happen AFTER the tags table is joined.
    // OR-within-section: any selected tag matches. `tag.id` is a UUID,
    // safe to inline.
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      final orClause = mutableFilter
          .map((t) => "JSON_EXTRACT(tags.tags, '\$.${t.id}') IS NOT NULL")
          .join(' OR ');
      query.where(CustomExpression<bool>('($orClause)'));
    }

    // Reaction filter: OR-within-section, AND'd against the tag predicate
    // via Drift's separate .where call.
    if (hasReactionFilter) {
      final orClause = reactionFilter
          .map(
            (e) =>
                "JSON_EXTRACT(reactions.reactions, ${emojiJsonPath(e)}) IS NOT NULL",
          )
          .join(' OR ');
      query.where(CustomExpression<bool>('($orClause)'));
    }

    return query;
  }

  /// A page-cursor for the activity feed: the `(unread_sort, activity_at,
  /// id)` tuple identifying the **last** row of a previously-emitted page,
  /// so the next page can resume with `(unread_sort, activity_at, id) <
  /// cursor`. Uses SQLite row-value comparison (≥ 3.15), which gives a
  /// strict total order matching the feed's `unread_sort DESC,
  /// activity_at DESC, id DESC` sort.
  static ({int unreadSort, String activityAt, ThreadId id}) feedCursor({
    required int unreadSort,
    required String activityAt,
    required ThreadId id,
  }) => (unreadSort: unreadSort, activityAt: activityAt, id: id);

  /// Shared filter/join machinery for activity-feed-style ID queries.
  /// Builds the FROM/JOIN/WHERE portion only — callers prepend their own
  /// SELECT clause, append GROUP BY and ORDER BY (plus any HAVING cursor
  /// predicate and LIMIT/OFFSET), and bind variables in the documented
  /// order.
  ///
  /// Variable order produced by this helper, in lookup order:
  /// 1. (if [priorityPath] != null) path, pathPrefix
  /// 2. (else if [priorityId] != null) priorityId
  /// 3. draft flag
  /// 4. (if [stateFlag] != null) state flag column
  /// 5. iconFilter values, in order
  /// 6. (if [requireTodoPredicate]) today, now, now, today, now, now
  ///
  /// The caller is responsible for any variables bound by its SELECT
  /// clause (e.g. the `now` for the activity_at end-of-window predicate)
  /// and for the cursor / LIMIT / OFFSET vars.
  static ({
    String sql,
    List<Variable> variables,
    Set<ResultSetImplementation<dynamic, dynamic>> readsFrom,
  })
  _buildFeedFilter({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    List<ActorId>? assigneeFilter,
    bool requireTodoPredicate = false,
    bool requireUnread = false,
    bool requireLinkSched = false,

    /// When set, restrict to threads with the named state flag = TRUE.
    /// Accepted values: 'active'. Anything else is ignored.
    String? stateFlag,

    /// Unified-feed section partition. The feed is split into three
    /// mutually-exclusive, independently-paginated streams keyed on the
    /// stored `unread` / `active` booleans (matching the `Thread.unread`
    /// getter and `primarySectionFor`, which the client display partition
    /// uses). Accepted values:
    ///   - 'unread' → `unread = 1`            (Updates cluster, top of Doing)
    ///   - 'active' → `active = 1 AND unread = 0` (read Doing + future Scheduled)
    ///   - 'done'   → `active = 0 AND unread = 0` (Activity / history tail)
    /// Anything else is ignored. Use the `unread` boolean (not `read_at`)
    /// so freshly-created read-but-never-opened active threads partition
    /// the same way the client does.
    String? sectionScope,
  }) {
    // Extract special tags (mirrors [_getQuery] / [_watchActivityFeedIds]
    // semantics).
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;
    if (mutableFilter?.remove(Tag.archived) == true) {
      archived = null;
    }
    final doTodo =
        requireTodoPredicate || (mutableFilter?.remove(Tag.todo) == true);
    final filterUnread =
        requireUnread || (mutableFilter?.remove(Tag.unread) == true);

    final variables = <Variable>[];
    final sqlBuf = StringBuffer();

    // FROM + standard joins. Per-user state lives on `a.*` since the
    // thread-state refactor, so there's no `user_sched` join. The shared
    // schedule is distinguished from link schedules by `link_id IS NULL`.
    sqlBuf.writeln('''
FROM threads a
LEFT JOIN schedules sched ON sched.thread_id = a.id AND sched.link_id IS NULL
LEFT JOIN links l ON l.thread_id = a.id''');

    // Action-tab queries need link_sched for bucket-date fallback (a
    // synced calendar event with an action set inherits its date from
    // the link's schedule). doTodo also needs it for its predicate.
    if (doTodo || requireLinkSched) {
      sqlBuf.writeln(
        'LEFT JOIN schedules link_sched ON link_sched.link_id = l.id',
      );
    }

    // Priority scope: exact filing only (flat priority model).
    if (priorityPath != null) {
      sqlBuf.writeln(
        'INNER JOIN priorities p ON p.id = a.priority_id AND p.path = ?',
      );
      variables.add(Variable.withString(priorityPath.toString()));
    }

    // WHERE clauses.
    final wheres = <String>[];
    if (priorityPath == null && priorityId != null) {
      wheres.add('a.priority_id = ?');
      variables.add(Variable.withBlob(priorityId.toBytes()));
    }
    if (archived == false) {
      wheres.add('a.archived_at IS NULL');
    } else if (archived == true) {
      wheres.add('a.archived_at IS NOT NULL');
    }
    wheres.add('a.draft = ?');
    variables.add(Variable.withInt(draft ? 1 : 0));
    if (filterUnread) {
      wheres.add('a.unread = 1 AND a.read_at IS NULL');
    }
    if (stateFlag == 'active') {
      wheres.add('a.$stateFlag = 1');
    }

    // Unified-feed section partition (mutually exclusive on the stored
    // `unread` / `active` booleans — see [sectionScope] doc above).
    if (sectionScope == 'unread') {
      wheres.add('COALESCE(a.unread, 0) = 1');
    } else if (sectionScope == 'active') {
      wheres.add('a.active = 1 AND COALESCE(a.unread, 0) = 0');
    } else if (sectionScope == 'done') {
      wheres.add('a.active = 0 AND COALESCE(a.unread, 0) = 0');
    }

    // Icon filter — mirrors [_getQuery] logic.
    if (iconFilter != null && iconFilter.isNotEmpty) {
      final includesLink = iconFilter.any(
        (v) => v == 'link' || v.startsWith('http'),
      );
      final others = iconFilter
          .where((v) => v != 'link' && !v.startsWith('http'))
          .toList();
      final preds = <String>[];
      if (includesLink) {
        preds.add("(a.icon = 'link' OR a.icon LIKE 'http%')");
      }
      if (others.isNotEmpty) {
        final placeholders = others.map((_) => '?').join(',');
        preds.add('a.icon IN ($placeholders)');
        for (final v in others) {
          variables.add(Variable.withString(v));
        }
      }
      if (preds.isNotEmpty) {
        wheres.add('(${preds.join(' OR ')})');
      }
    }

    // Assignee filter — match thread-level assignee_id (the contact the
    // thread is assigned to). OR-within-dimension across the selected
    // assignees; AND across other filter dimensions (via [wheres]).
    if (assigneeFilter != null && assigneeFilter.isNotEmpty) {
      final placeholders = assigneeFilter.map((_) => '?').join(',');
      wheres.add('a.assignee_id IN ($placeholders)');
      for (final id in assigneeFilter) {
        variables.add(Variable.withBlob(const ActorIdConverter().toSql(id)));
      }
    }

    // Search predicate — same shape as [_getQuery] (interpolated, not bound,
    // because the existing code relies on sanitized words and validated UUIDs).
    if (search?.isNotEmpty == true) {
      final sanitizedWords = _sanitizeSearchWords(search);
      if (sanitizedWords.isNotEmpty) {
        final ftsWords = _ftsQueryFromWords(sanitizedWords);
        final linkConditions = sanitizedWords
            .map(
              (word) => "(title LIKE '%$word%' OR source_url LIKE '%$word%')",
            )
            .join(' AND ');
        String? contactBranch;
        if (contactIdMatchesPerWord != null &&
            contactIdMatchesPerWord.length == sanitizedWords.length &&
            contactIdMatchesPerWord.every((ids) => ids.isNotEmpty)) {
          final clauses = <String>[];
          for (final ids in contactIdMatchesPerWord) {
            final orParts = ids
                .map(
                  (id) =>
                      "(',' || COALESCE(a.contacts, '') || ',') LIKE '%,$id,%'",
                )
                .join(' OR ');
            clauses.add('($orParts)');
          }
          contactBranch = clauses.join(' AND ');
        }
        final ftsBranch = ftsWords.isNotEmpty
            ? '''SELECT thread_id FROM thread_fts WHERE thread_fts MATCH '$ftsWords'
              UNION ALL
              SELECT thread_id FROM note_fts WHERE note_fts MATCH '$ftsWords'
              UNION ALL
              '''
            : '';
        wheres.add('''
(a.id IN (
  ${ftsBranch}SELECT thread_id FROM links WHERE thread_id IS NOT NULL AND $linkConditions
)${contactBranch != null ? ' OR ($contactBranch)' : ''})''');
      }
    }

    // Tag filter — hoist out of the join via EXISTS subqueries so tag rows
    // don't multiply the join. `tag.id` is a UUID, safe to interpolate.
    // OR-within-section: a single EXISTS with OR'd JSON_EXTRACTs.
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      final orClause = mutableFilter
          .map((t) => "JSON_EXTRACT(tt.tags, '\$.${t.id}') IS NOT NULL")
          .join(' OR ');
      wheres.add(
        "EXISTS (SELECT 1 FROM thread_tags tt "
        "WHERE tt.id = a.id AND tt.occurrence = '' "
        "AND ($orClause))",
      );
    }

    // Reaction filter — same EXISTS pattern over thread_reactions.
    // OR-within-section across emojis; AND across sections (via wheres).
    if (reactionFilter != null && reactionFilter.isNotEmpty) {
      final orClause = reactionFilter
          .map(
            (e) =>
                "JSON_EXTRACT(tr.reactions, ${emojiJsonPath(e)}) IS NOT NULL",
          )
          .join(' OR ');
      wheres.add(
        "EXISTS (SELECT 1 FROM thread_reactions tr "
        "WHERE tr.id = a.id AND tr.occurrence = '' "
        "AND ($orClause))",
      );
    }

    // doTodo: SQL form of [Thread.active] — at least one of shared schedule
    // currently in range, an unfinished active flag, or a link schedule
    // currently in range.
    if (doTodo) {
      final today = Date.today().toString();
      final now = Time.now();
      wheres.add(
        '''
((sched.start_on <= ? AND sched.start_at IS NULL) OR
 (sched.start_at <= ? AND (sched.end_at IS NULL OR sched.end_at >= ?)) OR
 (a.active = 1 AND a.read_at IS NULL) OR
 (link_sched.start_on <= ? AND link_sched.start_at IS NULL) OR
 (link_sched.start_at <= ? AND (link_sched.end_at IS NULL OR link_sched.end_at >= ?)))''',
      );
      variables.add(Variable.withString(today));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withString(today));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withDateTime(now));
    }

    if (wheres.isNotEmpty) {
      sqlBuf.writeln('WHERE ${wheres.join(' AND ')}');
    }

    final readsFrom = <ResultSetImplementation<dynamic, dynamic>>{
      Store.get.threads,
      Store.get.schedules,
      Store.get.links,
    };
    if (priorityPath != null) {
      readsFrom.add(Store.get.priorities);
    }
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      readsFrom.add(Store.get.threadTags);
    }
    if (reactionFilter != null && reactionFilter.isNotEmpty) {
      readsFrom.add(Store.get.threadReactions);
    }
    if (search?.isNotEmpty == true) {
      // FTS shadow tables are driven by triggers on threads and notes;
      // adding notes here ensures the watcher fires on new note content too.
      readsFrom.add(Store.get.notes);
    }

    return (sql: sqlBuf.toString(), variables: variables, readsFrom: readsFrom);
  }

  /// Phase 1 of the two-step activity-feed query. Returns just
  /// `(id, unread_sort, activity_at)` for each thread matching the feed
  /// filter, ordered by `unread_sort DESC, activity_at DESC, id DESC`.
  ///
  /// Critically, the query does `GROUP BY a.id` so the LIMIT applies to
  /// distinct threads rather than to the cartesian product of
  /// `threads × schedules × links`. The wide [_getQuery] form returns
  /// 4885+ raw rows for ~339 distinct threads; this form returns exactly
  /// one row per thread.
  ///
  /// When [after] is set, the query resumes from that cursor — the basis
  /// of the keyset-paginated sliding window. When null, the query starts
  /// from the head of the feed.
  ///
  /// Pair with [_hydrateActivityFeedRows] to fetch detail rows for the
  /// matched IDs and run them through [_mapResultsToThreads].
  static Stream<List<({ThreadId id, int unreadSort, String activityAt})>>
  _watchActivityFeedIds({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    int offset = 0,
    ({int unreadSort, String activityAt, ThreadId id})? after,
  }) {
    // Extract special tags (mirrors [_getQuery] semantics).
    final mutableFilter = filter != null ? List<Tag>.from(filter) : null;
    if (mutableFilter?.remove(Tag.archived) == true) {
      archived = null;
    }
    final doTodo = mutableFilter?.remove(Tag.todo) == true;
    final filterUnread = mutableFilter?.remove(Tag.unread) == true;

    final variables = <Variable>[];
    final sqlBuf = StringBuffer();
    final now = Time.now();

    // SELECT: identity + sort keys.
    // `unread_sort` is per-row but uniform within a thread's group.
    // `activity_at` collapses join rows via the OUTER aggregate MAX over the
    // INNER scalar MAX(...) of `(last note source, link source, created)`,
    // `(bumped, sentinel)`, and `(past shared-schedule end, sentinel)`.
    // Text comparison sorts ISO-8601 timestamps correctly; '0000' is the
    // sentinel that lexicographically sorts before any real timestamp so MAX
    // never picks it.
    sqlBuf.writeln('''
SELECT
  a.id AS id,
  CASE WHEN a.unread = 1 AND a.read_at IS NULL THEN 1 ELSE 0 END AS unread_sort,
  MAX(MAX(
    COALESCE(a.last_note_source_created_at, l.source_created_at, a.created_at),
    COALESCE(a.bumped_at, '0000'),
    CASE WHEN sched.end_at IS NOT NULL
          AND sched.occurrence IS NULL
          AND sched.end_at <= ?
         THEN sched.end_at
         ELSE '0000' END
  )) AS activity_at
FROM threads a
LEFT JOIN schedules sched ON sched.thread_id = a.id AND sched.link_id IS NULL
LEFT JOIN links l ON l.thread_id = a.id''');
    variables.add(Variable.withDateTime(now));

    // doTodo also needs link_sched. Per-user state lives directly on `a.*`
    // (active / task / to_read / read_at), so no user_sched join is required.
    if (doTodo) {
      sqlBuf.writeln(
        'LEFT JOIN schedules link_sched ON link_sched.link_id = l.id',
      );
    }

    // Priority scope: exact filing only (flat priority model).
    if (priorityPath != null) {
      sqlBuf.writeln(
        'INNER JOIN priorities p ON p.id = a.priority_id AND p.path = ?',
      );
      variables.add(Variable.withString(priorityPath.toString()));
    }

    // WHERE clauses.
    final wheres = <String>[];
    if (priorityPath == null && priorityId != null) {
      wheres.add('a.priority_id = ?');
      variables.add(Variable.withBlob(priorityId.toBytes()));
    }
    if (archived == false) {
      wheres.add('a.archived_at IS NULL');
    } else if (archived == true) {
      wheres.add('a.archived_at IS NOT NULL');
    }
    wheres.add('a.draft = ?');
    variables.add(Variable.withInt(draft ? 1 : 0));
    if (filterUnread) {
      wheres.add('a.unread = 1 AND a.read_at IS NULL');
    }

    // Icon filter — mirrors [_getQuery] logic.
    if (iconFilter != null && iconFilter.isNotEmpty) {
      final includesLink = iconFilter.any(
        (v) => v == 'link' || v.startsWith('http'),
      );
      final others = iconFilter
          .where((v) => v != 'link' && !v.startsWith('http'))
          .toList();
      final preds = <String>[];
      if (includesLink) {
        preds.add("(a.icon = 'link' OR a.icon LIKE 'http%')");
      }
      if (others.isNotEmpty) {
        final placeholders = others.map((_) => '?').join(',');
        preds.add('a.icon IN ($placeholders)');
        for (final v in others) {
          variables.add(Variable.withString(v));
        }
      }
      if (preds.isNotEmpty) {
        wheres.add('(${preds.join(' OR ')})');
      }
    }

    // Search predicate — same shape as [_getQuery] (interpolated, not bound,
    // because the existing code relies on sanitized words and validated UUIDs).
    if (search?.isNotEmpty == true) {
      final sanitizedWords = _sanitizeSearchWords(search);
      if (sanitizedWords.isNotEmpty) {
        final ftsWords = _ftsQueryFromWords(sanitizedWords);
        final linkConditions = sanitizedWords
            .map(
              (word) => "(title LIKE '%$word%' OR source_url LIKE '%$word%')",
            )
            .join(' AND ');
        String? contactBranch;
        if (contactIdMatchesPerWord != null &&
            contactIdMatchesPerWord.length == sanitizedWords.length &&
            contactIdMatchesPerWord.every((ids) => ids.isNotEmpty)) {
          final clauses = <String>[];
          for (final ids in contactIdMatchesPerWord) {
            final orParts = ids
                .map(
                  (id) =>
                      "(',' || COALESCE(a.contacts, '') || ',') LIKE '%,$id,%'",
                )
                .join(' OR ');
            clauses.add('($orParts)');
          }
          contactBranch = clauses.join(' AND ');
        }
        final ftsBranch = ftsWords.isNotEmpty
            ? '''SELECT thread_id FROM thread_fts WHERE thread_fts MATCH '$ftsWords'
              UNION ALL
              SELECT thread_id FROM note_fts WHERE note_fts MATCH '$ftsWords'
              UNION ALL
              '''
            : '';
        wheres.add('''
(a.id IN (
  ${ftsBranch}SELECT thread_id FROM links WHERE thread_id IS NOT NULL AND $linkConditions
)${contactBranch != null ? ' OR ($contactBranch)' : ''})''');
      }
    }

    // Tag filter — hoist out of the join via EXISTS subqueries so tag rows
    // don't multiply the join. `tag.id` is a UUID, safe to interpolate.
    // OR-within-section: a single EXISTS with OR'd JSON_EXTRACTs.
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      final orClause = mutableFilter
          .map((t) => "JSON_EXTRACT(tt.tags, '\$.${t.id}') IS NOT NULL")
          .join(' OR ');
      wheres.add(
        "EXISTS (SELECT 1 FROM thread_tags tt "
        "WHERE tt.id = a.id AND tt.occurrence = '' "
        "AND ($orClause))",
      );
    }

    // Reaction filter — same EXISTS pattern over thread_reactions.
    // OR-within-section across emojis; AND across sections (via wheres).
    if (reactionFilter != null && reactionFilter.isNotEmpty) {
      final orClause = reactionFilter
          .map(
            (e) =>
                "JSON_EXTRACT(tr.reactions, ${emojiJsonPath(e)}) IS NOT NULL",
          )
          .join(' OR ');
      wheres.add(
        "EXISTS (SELECT 1 FROM thread_reactions tr "
        "WHERE tr.id = a.id AND tr.occurrence = '' "
        "AND ($orClause))",
      );
    }

    // doTodo: SQL form of [Thread.active] — at least one of shared schedule
    // currently in range, an unfinished active flag, or a link schedule
    // currently in range.
    if (doTodo) {
      final today = Date.today().toString();
      wheres.add(
        '''
((sched.start_on <= ? AND sched.start_at IS NULL) OR
 (sched.start_at <= ? AND (sched.end_at IS NULL OR sched.end_at >= ?)) OR
 (a.active = 1 AND a.read_at IS NULL) OR
 (link_sched.start_on <= ? AND link_sched.start_at IS NULL) OR
 (link_sched.start_at <= ? AND (link_sched.end_at IS NULL OR link_sched.end_at >= ?)))''',
      );
      variables.add(Variable.withString(today));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withString(today));
      variables.add(Variable.withDateTime(now));
      variables.add(Variable.withDateTime(now));
    }

    if (wheres.isNotEmpty) {
      sqlBuf.writeln('WHERE ${wheres.join(' AND ')}');
    }

    sqlBuf.writeln('GROUP BY a.id');

    // Cursor predicate runs after GROUP BY because it compares against the
    // aggregated `unread_sort` / `activity_at` values.
    if (after != null) {
      sqlBuf.writeln('HAVING (unread_sort, activity_at, a.id) < (?, ?, ?)');
      variables.add(Variable.withInt(after.unreadSort));
      variables.add(Variable.withString(after.activityAt));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln('ORDER BY unread_sort DESC, activity_at DESC, a.id DESC');
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    final readsFrom = <ResultSetImplementation<dynamic, dynamic>>{
      Store.get.threads,
      Store.get.schedules,
      Store.get.links,
    };
    if (priorityPath != null) {
      readsFrom.add(Store.get.priorities);
    }
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      readsFrom.add(Store.get.threadTags);
    }
    if (reactionFilter != null && reactionFilter.isNotEmpty) {
      readsFrom.add(Store.get.threadReactions);
    }
    if (search?.isNotEmpty == true) {
      // FTS shadow tables are driven by triggers on threads and notes;
      // adding notes here ensures the watcher fires on new note content too.
      readsFrom.add(Store.get.notes);
    }

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  unreadSort: row.read<int>('unread_sort'),
                  activityAt: row.read<String>('activity_at'),
                ),
              )
              .toList(),
        );
  }

  /// One-shot variant of the activity-feed query for cursor-paginated
  /// scroll-down. Runs Phase 1 (ID selection with optional `after` cursor),
  /// then Phase 2 (detail hydration). Returns threads in feed order plus
  /// the tail cursor for the next page.
  ///
  /// The bloc layer uses this for "load more" beyond the live head watcher
  /// — pages it fetches are static snapshots that don't re-query on
  /// underlying table changes. The head watcher (driven by
  /// `Thread.watch(..., limit: pageSize)`) is the only live region.
  static Future<ActivityFeedPage> fetchActivityFeedPage({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    ({int unreadSort, String activityAt, ThreadId id})? after,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final idRows = await _watchActivityFeedIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      after: after,
    ).first;

    if (idRows.isEmpty) {
      return (threads: <Thread>[], nextCursor: null, saturated: false);
    }

    final ids = idRows.map((r) => r.id).toList();
    final detailRows = await _hydrateActivityFeedRows(ids);
    final threads = await _mapResultsToThreads(detailRows);

    final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    threads.sort(
      (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
        orderByIndex[y.id] ?? 1 << 30,
      ),
    );

    final last = idRows.last;
    return (
      threads: threads,
      nextCursor: (
        unreadSort: last.unreadSort,
        activityAt: last.activityAt,
        id: last.id,
      ),
      saturated: idRows.length >= limit,
    );
  }

  /// Phase 2 of the two-step activity-feed query: fetch detail rows for a
  /// specific set of thread IDs using the same 5-join shape as [_getQuery]
  /// so [_mapResultsToThreads] can consume them unchanged. No filtering or
  /// LIMIT — Phase 1 already established the membership and ordering.
  static Future<List<TypedResult>> _hydrateActivityFeedRows(
    List<ThreadId> ids,
  ) async {
    if (ids.isEmpty) return [];

    final a = Store.get.alias(Store.get.threads, 'a');
    final sched = Store.get.alias(Store.get.schedules, 'sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');
    final tags = Store.get.alias(Store.get.threadTags, 'tags');

    final query = Store.get.select(a).join([
      // Per-user state lives directly on the thread row, so no per-user
      // schedule join is needed.
      leftOuterJoin(
        sched,
        sched.threadId.equalsExp(a.id) & sched.linkId.isNull(),
      ),
      leftOuterJoin(linkTable, linkTable.threadId.equalsExp(a.id)),
      leftOuterJoin(linkSched, linkSched.linkId.equalsExp(linkTable.id)),
      leftOuterJoin(
        tags,
        (tags.id.equalsExp(a.id) | (tags.id.isNull() & a.id.isNull())) &
            (tags.occurrence.equalsExp(sched.occurrence) |
                (tags.occurrence.equals('') & sched.occurrence.isNull())),
      ),
    ]);

    query.where(a.id.isIn(ids.map((id) => id.toBytes()).toList()));
    return await query.get();
  }

  // ---------------------------------------------------------------------------
  // Per-tab activity-feed queries (new architecture).
  //
  // Each Activity Feed tab gets its own single SQL query that returns thread
  // IDs already in display order. Catch up and All produce flat lists.
  // Action tabs (Respond/Do/Read) additionally surface a bucket_date column
  // so the bloc can insert per-day headers at bucket transitions without
  // any in-memory partitioning.
  //
  // These methods are paired with the existing [_hydrateActivityFeedRows]
  // and [_mapResultsToThreads] for detail hydration — the row tuple they
  // return only needs to carry the ID plus the sort-key tuple needed to
  // express the next-page cursor. Cursor variables come last; all other
  // variables are bound by the shared [_buildFeedFilter].
  // ---------------------------------------------------------------------------

  /// Live stream of the Catch up tab's head page. Returns hydrated
  /// threads in display order along with the SQL-derived tail cursor
  /// (for pagination beyond the head) and whether the head was saturated.
  ///
  /// The bloc subscribes to this when Catch up is the active tab; on
  /// every emission it pairs the head with previously-fetched appended
  /// pages (via [fetchCatchUpPage]) to render the visible list.
  static Stream<
    ({
      List<Thread> threads,
      ({int urgent, int importance, String activityAt, ThreadId id})?
      tailCursor,
      bool saturated,
    })
  >
  watchCatchUpHead({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
  }) async* {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    yield* _watchCatchUpIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
    ).asyncMap((idRows) async {
      if (idRows.isEmpty) {
        return (threads: <Thread>[], tailCursor: null, saturated: false);
      }
      final ids = idRows.map((r) => r.id).toList();
      final detailRows = await _hydrateActivityFeedRows(ids);
      final threads = await _mapResultsToThreads(detailRows);
      final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      threads.sort(
        (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
          orderByIndex[y.id] ?? 1 << 30,
        ),
      );
      final last = idRows.last;
      return (
        threads: threads,
        tailCursor: (
          urgent: last.urgent,
          importance: last.importance,
          activityAt: last.activityAt,
          id: last.id,
        ),
        saturated: idRows.length >= limit,
      );
    });
  }

  /// Page result for the Catch up tab's cursor pagination. Mirrors
  /// [ActivityFeedPage] but with the urgency-keyed cursor shape.
  static Future<
    ({
      List<Thread> threads,
      ({int urgent, int importance, String activityAt, ThreadId id})?
      nextCursor,
      bool saturated,
    })
  >
  fetchCatchUpPage({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    ({int urgent, int importance, String activityAt, ThreadId id})? after,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final idRows = await _watchCatchUpIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      after: after,
    ).first;

    if (idRows.isEmpty) {
      return (threads: <Thread>[], nextCursor: null, saturated: false);
    }

    final ids = idRows.map((r) => r.id).toList();
    final detailRows = await _hydrateActivityFeedRows(ids);
    final threads = await _mapResultsToThreads(detailRows);

    final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    threads.sort(
      (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
        orderByIndex[y.id] ?? 1 << 30,
      ),
    );

    final last = idRows.last;
    return (
      threads: threads,
      nextCursor: (
        urgent: last.urgent,
        importance: last.importance,
        activityAt: last.activityAt,
        id: last.id,
      ),
      saturated: idRows.length >= limit,
    );
  }

  /// Phase 1 of the Catch up tab's query. Returns
  /// `(id, urgent, importance, activity_at)` per row for every unread thread
  /// the user can see, ordered by `urgent DESC, importance DESC,
  /// activity_at DESC, id DESC`.
  ///
  /// Pair with [_hydrateActivityFeedRows] for detail hydration.
  static Stream<
    List<({ThreadId id, int urgent, int importance, String activityAt})>
  >
  _watchCatchUpIds({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    int offset = 0,
    ({int urgent, int importance, String activityAt, ThreadId id})? after,
  }) {
    final variables = <Variable>[];
    final sqlBuf = StringBuffer();
    final now = Time.now();

    // SELECT: identity + sort keys. `urgent` is nullable; COALESCE to 0 so
    // the integer comparison matches Dart's `bool == true` semantic.
    // `activity_at` follows the same formula as [_watchActivityFeedIds].
    sqlBuf.writeln('''
SELECT
  a.id AS id,
  COALESCE(a.urgent, 0) AS urgent,
  a.importance AS importance,
  MAX(MAX(
    COALESCE(a.last_note_source_created_at, l.source_created_at, a.created_at),
    COALESCE(a.bumped_at, '0000'),
    CASE WHEN sched.end_at IS NOT NULL
          AND sched.occurrence IS NULL
          AND sched.end_at <= ?
         THEN sched.end_at
         ELSE '0000' END
  )) AS activity_at''');
    variables.add(Variable.withDateTime(now));

    final parts = _buildFeedFilter(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      requireUnread: true,
    );
    sqlBuf.write(parts.sql);
    variables.addAll(parts.variables);

    sqlBuf.writeln('GROUP BY a.id');

    // Cursor predicate runs after GROUP BY because `urgent` / `importance`
    // are taken from `a.*` directly but the row-value comparison is
    // semantically post-aggregation (mixed with `activity_at`).
    if (after != null) {
      sqlBuf.writeln(
        'HAVING (urgent, importance, activity_at, a.id) < (?, ?, ?, ?)',
      );
      variables.add(Variable.withInt(after.urgent));
      variables.add(Variable.withInt(after.importance));
      variables.add(Variable.withString(after.activityAt));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln(
      'ORDER BY urgent DESC, importance DESC, activity_at DESC, a.id DESC',
    );
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: parts.readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  urgent: row.read<int>('urgent'),
                  importance: row.read<int>('importance'),
                  activityAt: row.read<String>('activity_at'),
                ),
              )
              .toList(),
        );
  }

  /// Live stream of the All tab's head page. Mirrors [watchCatchUpHead]
  /// but with the unified-feed cursor shape — see [_watchAllTabIds].
  static Stream<
    ({
      List<Thread> threads,
      ({String activityAt, ThreadId id})? tailCursor,
      bool saturated,
    })
  >
  watchAllTabHead({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    List<ActorId>? assigneeFilter,
    required int limit,
  }) async* {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    yield* _watchAllTabIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      assigneeFilter: assigneeFilter,
      limit: limit,
    ).asyncMap((idRows) async {
      if (idRows.isEmpty) {
        return (threads: <Thread>[], tailCursor: null, saturated: false);
      }
      final ids = idRows.map((r) => r.id).toList();
      final detailRows = await _hydrateActivityFeedRows(ids);
      final threads = await _mapResultsToThreads(detailRows);
      final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      threads.sort(
        (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
          orderByIndex[y.id] ?? 1 << 30,
        ),
      );
      final last = idRows.last;
      return (
        threads: threads,
        tailCursor: (activityAt: last.activityAt, id: last.id),
        saturated: idRows.length >= limit,
      );
    });
  }

  /// Page result for the All tab's cursor pagination.
  static Future<
    ({
      List<Thread> threads,
      ({String activityAt, ThreadId id})? nextCursor,
      bool saturated,
    })
  >
  fetchAllTabPage({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    ({String activityAt, ThreadId id})? after,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final idRows = await _watchAllTabIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      after: after,
    ).first;

    if (idRows.isEmpty) {
      return (threads: <Thread>[], nextCursor: null, saturated: false);
    }

    final ids = idRows.map((r) => r.id).toList();
    final detailRows = await _hydrateActivityFeedRows(ids);
    final threads = await _mapResultsToThreads(detailRows);

    final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    threads.sort(
      (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
        orderByIndex[y.id] ?? 1 << 30,
      ),
    );

    final last = idRows.last;
    return (
      threads: threads,
      nextCursor: (activityAt: last.activityAt, id: last.id),
      saturated: idRows.length >= limit,
    );
  }

  /// Phase 1 of the All tab's query. Returns `(id, activity_at)` per row for
  /// every visible thread, ordered by `activity_at DESC, id DESC`.
  ///
  /// The flat feed (Everything / search / filter / icon) loads and sorts
  /// purely by recency, exactly like the Done section's [_watchDoneIds] — read
  /// state and importance do not lift a thread above a more recently-active
  /// one. (The unread cluster's importance/urgent ordering lives in the
  /// sectioned feeds' [watchUnreadHead], which this query never feeds.)
  static Stream<List<({ThreadId id, String activityAt})>> _watchAllTabIds({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    List<ActorId>? assigneeFilter,
    required int limit,
    int offset = 0,
    ({String activityAt, ThreadId id})? after,
  }) {
    final variables = <Variable>[];
    final sqlBuf = StringBuffer();
    final now = Time.now();

    sqlBuf.writeln('''
SELECT
  a.id AS id,
  MAX(MAX(
    COALESCE(a.last_note_source_created_at, l.source_created_at, a.created_at),
    COALESCE(a.bumped_at, '0000'),
    CASE WHEN sched.end_at IS NOT NULL
          AND sched.occurrence IS NULL
          AND sched.end_at <= ?
         THEN sched.end_at
         ELSE '0000' END
  )) AS activity_at''');
    variables.add(Variable.withDateTime(now));

    final parts = _buildFeedFilter(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      assigneeFilter: assigneeFilter,
    );
    sqlBuf.write(parts.sql);
    variables.addAll(parts.variables);

    sqlBuf.writeln('GROUP BY a.id');

    if (after != null) {
      sqlBuf.writeln('HAVING (activity_at, a.id) < (?, ?)');
      variables.add(Variable.withString(after.activityAt));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln('ORDER BY activity_at DESC, a.id DESC');
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: parts.readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  activityAt: row.read<String>('activity_at'),
                ),
              )
              .toList(),
        );
  }

  /// Live stream of the action tab's head page (Respond / Do / Read).
  /// Mirrors [watchCatchUpHead] but parameterised by `action` and carrying
  /// the bucket cursor shape — see [_watchActionTabIds].
  static Stream<
    ({
      List<Thread> threads,
      ({int isActiveInv, String bucketKey, double order, ThreadId id})?
      tailCursor,
      bool saturated,
    })
  >
  watchActionTabHead({
    required String action,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    String? sectionScope,
  }) async* {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    yield* _watchActionTabIds(
      action: action,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      sectionScope: sectionScope,
    ).asyncMap((idRows) async {
      if (idRows.isEmpty) {
        return (threads: <Thread>[], tailCursor: null, saturated: false);
      }
      final ids = idRows.map((r) => r.id).toList();
      final detailRows = await _hydrateActivityFeedRows(ids);
      final threads = await _mapResultsToThreads(detailRows);
      final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      threads.sort(
        (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
          orderByIndex[y.id] ?? 1 << 30,
        ),
      );
      final last = idRows.last;
      return (
        threads: threads,
        tailCursor: (
          isActiveInv: last.isActive ? 0 : 1,
          bucketKey: last.isActive ? '0000' : (last.bucketDate ?? '9999'),
          order: last.order,
          id: last.id,
        ),
        saturated: idRows.length >= limit,
      );
    });
  }

  /// Page result for the Respond / Do / Read action tabs. Each row carries
  /// the bucket assignment so the renderer can insert date headers at
  /// transitions without re-bucketing in Dart. `isActive=true` rows render
  /// in the Today bucket; `isActive=false` rows render under the scheduled
  /// day named by `bucketDate`.
  static Future<
    ({
      List<Thread> threads,
      List<({ThreadId id, bool isActive, String? bucketDate, double order})>
      rows,
      ({int isActiveInv, String bucketKey, double order, ThreadId id})?
      nextCursor,
      bool saturated,
    })
  >
  fetchActionTabPage({
    required String action,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    ({int isActiveInv, String bucketKey, double order, ThreadId id})? after,
    String? sectionScope,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final idRows = await _watchActionTabIds(
      action: action,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      after: after,
      sectionScope: sectionScope,
    ).first;

    if (idRows.isEmpty) {
      return (
        threads: <Thread>[],
        rows:
            <
              ({ThreadId id, bool isActive, String? bucketDate, double order})
            >[],
        nextCursor: null,
        saturated: false,
      );
    }

    final ids = idRows.map((r) => r.id).toList();
    final detailRows = await _hydrateActivityFeedRows(ids);
    final threads = await _mapResultsToThreads(detailRows);

    final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    threads.sort(
      (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
        orderByIndex[y.id] ?? 1 << 30,
      ),
    );

    final last = idRows.last;
    return (
      threads: threads,
      rows: idRows,
      nextCursor: (
        isActiveInv: last.isActive ? 0 : 1,
        bucketKey: last.isActive ? '0000' : (last.bucketDate ?? '9999'),
        order: last.order,
        id: last.id,
      ),
      saturated: idRows.length >= limit,
    );
  }

  /// Phase 1 of the action-tab query (Respond / Do / Read). Returns
  /// `(id, is_active, bucket_date, state_order)` per row, ordered so that
  /// active (today/past) threads come first followed by scheduled rows in
  /// ascending date order, then by user-chosen `state_order`.
  ///
  /// `bucket_date` is `NULL` only when the thread has no schedule at all
  /// AND no per-user state date — in which case it sorts as active (the
  /// renderer's Today bucket). For scheduled rows it's the user state date
  /// when set, falling back to the shared schedule, then to the link
  /// schedule.
  ///
  /// Pair with [_hydrateActivityFeedRows] for detail hydration.
  static Stream<
    List<({ThreadId id, bool isActive, String? bucketDate, double order})>
  >
  _watchActionTabIds({
    required String action,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    int offset = 0,
    ({int isActiveInv, String bucketKey, double order, ThreadId id})? after,

    /// Unified-feed partition (see [_buildFeedFilter.sectionScope]). When
    /// set (e.g. 'active'), the section predicate replaces the legacy
    /// `stateFlag` + `read_at IS NULL` shim so the active+scheduled stream
    /// is the exact complement of the unread stream (keyed on the stored
    /// `unread` boolean, not `read_at`).
    String? sectionScope,
  }) {
    final variables = <Variable>[];
    final sqlBuf = StringBuffer();
    final today = Date.today().toString();

    // SELECT: identity + the three sort keys plus the bucket-date that the
    // renderer uses to insert headers. `is_active` is computed from the
    // same date sources as the Dart `Thread.isActiveThread` predicate
    // (state_on / state_at / sched / link_sched), with NULL bucket dates
    // treated as active.
    sqlBuf.writeln('''
SELECT
  a.id AS id,
  CASE WHEN
    (a.state_on IS NOT NULL AND a.state_on <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NOT NULL AND DATE(a.state_at) <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NULL
        AND sched.start_on IS NOT NULL AND sched.start_on <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NULL
        AND sched.start_on IS NULL AND sched.start_at IS NOT NULL
        AND DATE(sched.start_at) <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NULL
        AND sched.start_on IS NULL AND sched.start_at IS NULL
        AND link_sched.start_on IS NOT NULL AND link_sched.start_on <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NULL
        AND sched.start_on IS NULL AND sched.start_at IS NULL
        AND link_sched.start_on IS NULL AND link_sched.start_at IS NOT NULL
        AND DATE(link_sched.start_at) <= ?)
    OR (a.state_on IS NULL AND a.state_at IS NULL
        AND sched.start_on IS NULL AND sched.start_at IS NULL
        AND link_sched.start_on IS NULL AND link_sched.start_at IS NULL)
  THEN 1 ELSE 0 END AS is_active,
  COALESCE(
    a.state_on,
    CASE WHEN a.state_at IS NOT NULL THEN DATE(a.state_at) ELSE NULL END,
    sched.start_on,
    CASE WHEN sched.start_at IS NOT NULL THEN DATE(sched.start_at) ELSE NULL END,
    link_sched.start_on,
    CASE WHEN link_sched.start_at IS NOT NULL
         THEN DATE(link_sched.start_at) ELSE NULL END
  ) AS bucket_date,
  COALESCE(a.state_order, 0) AS state_order''');
    // The six `<= today` comparisons in the is_active CASE.
    for (var i = 0; i < 6; i++) {
      variables.add(Variable.withString(today));
    }

    final parts = _buildFeedFilter(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      requireLinkSched: true,
      // When a unified-feed section is requested, the partition predicate
      // owns the state filter; otherwise fall back to the legacy stateFlag.
      stateFlag: sectionScope == null ? action : null,
      sectionScope: sectionScope,
    );
    sqlBuf.write(parts.sql);
    variables.addAll(parts.variables);

    if (sectionScope == null) {
      // Legacy action-tab caller passes whatever flag it cares about as
      // `action`; pair it with the unread half of the active predicate so
      // threads the user has marked read drop out.
      sqlBuf.writeln('AND a.read_at IS NULL');
    }
    // For the unified active+scheduled stream (sectionScope == 'active') the
    // `active = 1 AND unread = 0` partition already selects exactly the
    // read-active rows, so no read_at shim is applied.

    sqlBuf.writeln('GROUP BY a.id');

    // Cursor predicate. The visible sort is
    //   `is_active DESC, bucket_key ASC, state_order ASC, id ASC`
    // expressed as ascending across `is_active_inv = (1 - is_active)`,
    // a normalized bucket key ('0000' for active, COALESCE date for
    // scheduled, '9999' for unscheduled), state_order, and id.
    if (after != null) {
      sqlBuf.writeln('''
HAVING (
  (1 - is_active),
  CASE WHEN is_active = 1 THEN '0000' ELSE COALESCE(bucket_date, '9999') END,
  state_order,
  a.id
) > (?, ?, ?, ?)''');
      variables.add(Variable.withInt(after.isActiveInv));
      variables.add(Variable.withString(after.bucketKey));
      variables.add(Variable.withReal(after.order));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln('''
ORDER BY
  (1 - is_active) ASC,
  CASE WHEN is_active = 1 THEN '0000' ELSE COALESCE(bucket_date, '9999') END ASC,
  state_order ASC,
  a.id ASC''');
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: parts.readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  isActive: row.read<int>('is_active') == 1,
                  bucketDate: row.readNullable<String>('bucket_date'),
                  order: row.read<double>('state_order'),
                ),
              )
              .toList(),
        );
  }

  // ---------------------------------------------------------------------------
  // Unified-feed section streams (Unread / Active+Scheduled / Done).
  //
  // The feed is fetched as three mutually-exclusive, independently-sorted,
  // independently-paginated streams instead of one query that is sectioned
  // client-side. With thousands of threads at a rolled-up priority, a single
  // `activity_at DESC` page is dominated by recently-touched *done* threads,
  // so the bounded Unread / Active sets fall past the LIMIT and never render.
  // Splitting by section guarantees each section surfaces regardless of the
  // done-tail volume. Active+Scheduled is served by
  // [watchActionTabHead(action: 'active', sectionScope: 'active')].
  // ---------------------------------------------------------------------------

  /// Live head of the unified feed's **Unread** stream. Returns hydrated
  /// unread threads in `unreadDoing` display order (urgent DESC,
  /// importance DESC, state_order ASC, id ASC) plus the keyset tail cursor.
  static Stream<
    ({
      List<Thread> threads,
      ({int urgent, int importance, double order, ThreadId id})? tailCursor,
      bool saturated,
    })
  >
  watchUnreadHead({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
  }) async* {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    yield* _watchUnreadIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
    ).asyncMap((idRows) async {
      if (idRows.isEmpty) {
        return (threads: <Thread>[], tailCursor: null, saturated: false);
      }
      final ids = idRows.map((r) => r.id).toList();
      final detailRows = await _hydrateActivityFeedRows(ids);
      final threads = await _mapResultsToThreads(detailRows);
      final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      threads.sort(
        (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
          orderByIndex[y.id] ?? 1 << 30,
        ),
      );
      final last = idRows.last;
      return (
        threads: threads,
        tailCursor: (
          urgent: last.urgent,
          importance: last.importance,
          order: last.order,
          id: last.id,
        ),
        saturated: idRows.length >= limit,
      );
    });
  }

  /// Phase 1 of the Unread stream: `(id, urgent, importance, state_order)`
  /// per unread thread. The display order is mixed-direction
  /// (urgent DESC, importance DESC, state_order ASC, id ASC); it is expressed
  /// all-ascending over `(1 - urgent, -importance, state_order, id)` so the
  /// keyset cursor stays monotonic. Pair with [_hydrateActivityFeedRows].
  static Stream<List<({ThreadId id, int urgent, int importance, double order})>>
  _watchUnreadIds({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    int offset = 0,
    ({int urgent, int importance, double order, ThreadId id})? after,
  }) {
    final variables = <Variable>[];
    final sqlBuf = StringBuffer();

    sqlBuf.writeln('''
SELECT
  a.id AS id,
  COALESCE(a.urgent, 0) AS urgent,
  a.importance AS importance,
  COALESCE(a.state_order, 0) AS state_order''');

    final parts = _buildFeedFilter(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      sectionScope: 'unread',
    );
    sqlBuf.write(parts.sql);
    variables.addAll(parts.variables);

    sqlBuf.writeln('GROUP BY a.id');

    if (after != null) {
      sqlBuf.writeln(
        'HAVING ((1 - urgent), -importance, state_order, a.id) > (?, ?, ?, ?)',
      );
      variables.add(Variable.withInt(1 - after.urgent));
      variables.add(Variable.withInt(-after.importance));
      variables.add(Variable.withReal(after.order));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln(
      'ORDER BY (1 - urgent) ASC, -importance ASC, state_order ASC, a.id ASC',
    );
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: parts.readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  urgent: row.read<int>('urgent'),
                  importance: row.read<int>('importance'),
                  order: row.read<double>('state_order'),
                ),
              )
              .toList(),
        );
  }

  /// Live head of the unified feed's **Done** stream (the read history
  /// tail). Ordered `activity_at DESC, id DESC` — the same recency formula
  /// and `(activity_at, id)` cursor as the legacy activity-feed query, but
  /// restricted to `active = 0 AND unread = 0`. This is the only section
  /// that paginates on scroll (see [fetchDonePage]).
  static Stream<
    ({
      List<Thread> threads,
      ({String activityAt, ThreadId id})? tailCursor,
      bool saturated,
    })
  >
  watchDoneHead({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
  }) async* {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    yield* _watchDoneIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
    ).asyncMap((idRows) async {
      if (idRows.isEmpty) {
        return (threads: <Thread>[], tailCursor: null, saturated: false);
      }
      final ids = idRows.map((r) => r.id).toList();
      final detailRows = await _hydrateActivityFeedRows(ids);
      final threads = await _mapResultsToThreads(detailRows);
      final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      threads.sort(
        (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
          orderByIndex[y.id] ?? 1 << 30,
        ),
      );
      final last = idRows.last;
      return (
        threads: threads,
        tailCursor: (activityAt: last.activityAt, id: last.id),
        saturated: idRows.length >= limit,
      );
    });
  }

  /// One-shot Done page for cursor-paginated scroll-down. Mirrors
  /// [fetchActivityFeedPage] but uses the Done partition and `(activity_at,
  /// id)` cursor.
  static Future<
    ({
      List<Thread> threads,
      ({String activityAt, ThreadId id})? nextCursor,
      bool saturated,
    })
  >
  fetchDonePage({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    ({String activityAt, ThreadId id})? after,
  }) async {
    final contactIdMatchesPerWord = await _resolveContactIdMatches(search);
    final idRows = await _watchDoneIds(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      limit: limit,
      after: after,
    ).first;

    if (idRows.isEmpty) {
      return (threads: <Thread>[], nextCursor: null, saturated: false);
    }

    final ids = idRows.map((r) => r.id).toList();
    final detailRows = await _hydrateActivityFeedRows(ids);
    final threads = await _mapResultsToThreads(detailRows);
    final orderByIndex = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    threads.sort(
      (x, y) => (orderByIndex[x.id] ?? 1 << 30).compareTo(
        orderByIndex[y.id] ?? 1 << 30,
      ),
    );
    final last = idRows.last;
    return (
      threads: threads,
      nextCursor: (activityAt: last.activityAt, id: last.id),
      saturated: idRows.length >= limit,
    );
  }

  /// Phase 1 of the Done stream: `(id, activity_at)` per read/inactive
  /// thread, ordered `activity_at DESC, id DESC`. `activity_at` uses the
  /// established recency formula (see [_watchAllTabIds]) so the cursor stays
  /// monotonic with the Dart `Thread.activityAt` getter.
  static Stream<List<({ThreadId id, String activityAt})>> _watchDoneIds({
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool draft = false,
    String? search,
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
    List<Reaction>? reactionFilter,
    List<String>? iconFilter,
    required int limit,
    int offset = 0,
    ({String activityAt, ThreadId id})? after,
  }) {
    final variables = <Variable>[];
    final sqlBuf = StringBuffer();
    final now = Time.now();

    sqlBuf.writeln('''
SELECT
  a.id AS id,
  MAX(MAX(
    COALESCE(a.last_note_source_created_at, l.source_created_at, a.created_at),
    COALESCE(a.bumped_at, '0000'),
    CASE WHEN sched.end_at IS NOT NULL
          AND sched.occurrence IS NULL
          AND sched.end_at <= ?
         THEN sched.end_at
         ELSE '0000' END
  )) AS activity_at''');
    variables.add(Variable.withDateTime(now));

    final parts = _buildFeedFilter(
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
      reactionFilter: reactionFilter,
      iconFilter: iconFilter,
      sectionScope: 'done',
    );
    sqlBuf.write(parts.sql);
    variables.addAll(parts.variables);

    sqlBuf.writeln('GROUP BY a.id');

    if (after != null) {
      sqlBuf.writeln('HAVING (activity_at, a.id) < (?, ?)');
      variables.add(Variable.withString(after.activityAt));
      variables.add(Variable.withBlob(after.id.toBytes()));
    }

    sqlBuf.writeln('ORDER BY activity_at DESC, a.id DESC');
    sqlBuf.writeln('LIMIT ? OFFSET ?');
    variables.add(Variable.withInt(limit));
    variables.add(Variable.withInt(offset));

    return Store.get
        .customSelect(
          sqlBuf.toString(),
          variables: variables,
          readsFrom: parts.readsFrom,
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => (
                  id: Uuid.fromBytes(row.read<Uint8List>('id')),
                  activityAt: row.read<String>('activity_at'),
                ),
              )
              .toList(),
        );
  }

  /// Efficiently gets which activity IDs from the given list are active.
  /// An activity is active if it's an action assigned to current user,
  /// not done, not archived, and scheduled for now/past or unscheduled.
  static Future<Set<ThreadId>> _getActiveThreadIds(List<ThreadId> ids) async {
    if (ids.isEmpty) return {};
    if (!Store.isAvailable) return {};

    final now = Time.now();
    final today = Date.today().toString();

    // Get all user contact IDs from Actor cache
    final userActorIds = Actor._cache.values
        .where((actor) => actor.self)
        .map((actor) => actor.id.toBytes())
        .toList();

    // Fallback to primary contact if cache is empty
    if (userActorIds.isEmpty) {
      final id = Base.actorIdOrNull;
      if (id != null) {
        userActorIds.add(id.toBytes());
      } else {
        return {};
      }
    }

    final a = Store.get.threads;
    final s = Store.get.schedules;
    final query = Store.get.selectOnly(a)..addColumns([a.id]);

    query.join([leftOuterJoin(s, s.threadId.equalsExp(a.id))]);

    // Convert ThreadId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.id.isIn(idBytes) &
          a.archivedAt.isNull() &
          (
          // DateTime scheduled
          (s.startAt.isSmallerOrEqualValue(now) & s.startOn.isNull()) |
              // Date scheduled
              (s.startOn.isSmallerOrEqualValue(today) & s.startAt.isNull()) |
              // Unscheduled (no schedule row at all)
              (s.startAt.isNull() & s.startOn.isNull())),
    );

    final results = await query.get();
    return results.map((row) => Uuid.fromBytes(row.read(a.id)!)).toSet();
  }

  /// Efficiently gets which activity IDs from the given list are unread.
  /// An activity is unread if server says unread and we haven't overridden it locally.
  static Future<Set<ThreadId>> _getUnreadThreadIds(List<ThreadId> ids) async {
    if (ids.isEmpty) return {};
    if (!Store.isAvailable) return {};

    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.id]);

    // Convert ThreadId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(a.id.isIn(idBytes) & a.unread.equals(true) & a.readAt.isNull());

    final results = await query.get();
    return results.map((row) => Uuid.fromBytes(row.read(a.id)!)).toSet();
  }

  /// Maps database query results to Activity objects.
  ///
  /// This function handles both regular and recurring activities:
  /// - For non-recurring activities: Returns them directly
  /// - For recurring activities with a range: Generates occurrences within the range
  /// - For recurring activities without a range: Returns the base recurring activity template
  ///
  /// Recurring activities can have exceptions (modified/archived occurrences) stored in
  /// the activity_exceptions table, which override generated occurrences.
  static Future<List<Thread>> _mapResultsToThreads(
    List<TypedResult> results, {
    bool? archived = false,
    DateRange? range,
  }) async {
    if (results.isEmpty) return [];

    // Get the table aliases (we need to recreate these for reading)
    final a = Store.get.alias(Store.get.threads, 'a');
    final tags = Store.get.alias(Store.get.threadTags, 'tags');
    final sched = Store.get.alias(Store.get.schedules, 'sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');

    // Get all priorities needed for the activities. Uses the raw lookup
    // (no network pullArchived, no active/unread enrichment) — agenda
    // rendering only needs identity / path / display fields, and this
    // lookup runs on every Drift emission so the extra queries dominate
    // the agenda's cold-start gating time.
    final priorities = await Priority.getRaw(archived: null);
    if (!Store.isAvailable) return [];
    final priorityMap = Priority.asMap(priorities);

    // Group results by activity ID to handle schedule occurrences
    final activityGroups = <Uuid, List<TypedResult>>{};
    for (final result in results) {
      final activityId = result.readTable(a).id;
      activityGroups.putIfAbsent(activityId, () => []).add(result);
    }

    // Compute which activities are active and unread (efficient bulk queries)
    final activityIds = activityGroups.keys.toList();
    final activeIds = await _getActiveThreadIds(activityIds);
    final unreadIds = await _getUnreadThreadIds(activityIds);

    // Separate recurring activities from non-recurring and collect schedule occurrences
    final threadList = <Thread>[];
    for (final group in activityGroups.values) {
      final activityRow = group.first.readTable(a);
      final priority = priorityMap[activityRow.priorityId];
      if (priority == null) {
        // Skip activities with missing priority (e.g., priority was deleted or archived)
        continue;
      }

      // Read the base schedule (first row without an occurrence, or just the first).
      // Per-user state lives on the thread row itself (activityRow), so we
      // no longer read a separate user_schedule row.
      final baseScheduleRow = group.first.readTableOrNull(sched);

      // Extract max link source_created_at for activity_at computation
      DateTime? linkSourceCreatedAt;
      for (final result in group) {
        final linkRow = result.readTableOrNull(linkTable);
        if (linkRow != null) {
          final lsc = linkRow.sourceCreatedAt;
          if (linkSourceCreatedAt == null || lsc.isAfter(linkSourceCreatedAt)) {
            linkSourceCreatedAt = lsc;
          }
        }
      }

      // When the thread has no own schedule, pick the closest upcoming link
      // schedule so that Thread.at is populated for display purposes.
      ScheduleRow? effectiveScheduleRow = baseScheduleRow;
      if (baseScheduleRow == null) {
        final now = Time.now();
        ScheduleRow? bestFuture;
        DateTime? bestFutureStart;
        ScheduleRow? bestPast;
        DateTime? bestPastStart;
        for (final result in group) {
          final ls = result.readTableOrNull(linkSched);
          if (ls == null) continue;
          final start = ls.startAt ?? ls.startOn?.toDateTime();
          if (start == null) continue;
          if (start.isAfter(now)) {
            if (bestFutureStart == null || start.isBefore(bestFutureStart)) {
              bestFuture = ls;
              bestFutureStart = start;
            }
          } else {
            if (bestPastStart == null || start.isAfter(bestPastStart)) {
              bestPast = ls;
              bestPastStart = start;
            }
          }
        }
        effectiveScheduleRow = bestFuture ?? bestPast;
      }

      // Determine if this is recurring from the schedule
      final isRecurring =
          baseScheduleRow?.recurrenceRule != null &&
          baseScheduleRow?.occurrence == null;

      // Create base activity
      final tagsRow = !isRecurring ? group.first.readTableOrNull(tags) : null;
      final baseActivity = Thread._fromStore(
        activity: activityRow,
        priority: priority,
        schedule: effectiveScheduleRow,
        tags: tagsRow,
        active: activeIds.contains(activityRow.id),
        unreadComputed: unreadIds.contains(activityRow.id),
        linkSourceCreatedAt: linkSourceCreatedAt,
        rsvpInheritedFromSeries: false,
      );

      // Collect link schedules upfront so we can decide whether to include
      // the base thread (avoids duplicating it alongside its link instances).
      final linkSchedules = <String, ScheduleRow>{};
      if (range != null) {
        for (final result in group) {
          final linkScheduleRow = result.readTableOrNull(linkSched);
          if (linkScheduleRow != null) {
            // Key by linkId + occurrence to deduplicate base schedules per link
            final key =
                '${linkScheduleRow.linkId}:${linkScheduleRow.occurrence ?? ''}';
            final existing = linkSchedules[key];
            if (existing == null ||
                linkScheduleRow.updatedAt.isAfter(existing.updatedAt)) {
              linkSchedules[key] = linkScheduleRow;
            }
          }
        }
      }

      if (!isRecurring) {
        // Skip the base thread when link schedule instances fully represent it:
        // - link schedules exist (the instances will appear at their own dates)
        // - thread is not a todo (todos need to appear under today)
        // - thread has no own shared schedule (no event time of its own)
        final hasOwnSchedule =
            baseScheduleRow?.startOn != null ||
            baseScheduleRow?.startAt != null;
        if (linkSchedules.isEmpty || baseActivity.todo || hasOwnSchedule) {
          threadList.add(baseActivity);
        }
      } else {
        // If the base recurring thread schedule is archived, the entire
        // series was cancelled. Skip materialising instances for the agenda.
        // The thread still appears in the activity feed via the no-range
        // path below.
        if (baseScheduleRow?.archivedAt != null) {
          if (range?.bounded != true) {
            threadList.add(baseActivity);
          }
          continue;
        }
        // Generate occurrences for recurring activities and override with stored schedule occurrences
        final occurrences = <String, Thread>{};
        if (range?.bounded == true) {
          try {
            for (final occurrence in baseActivity.generateOccurrences(
              range!.toBounded(),
            )) {
              occurrences[occurrence._schedule!.occurrence!] = occurrence;
            }
            // Overwrite occurrences with stored schedule occurrences
            final overrideDateOnly = baseScheduleRow?.startAt == null;
            for (final result in group) {
              final scheduleRow = result.readTableOrNull(sched);
              if (scheduleRow == null || scheduleRow.occurrence == null) {
                continue;
              }
              final overrideKey = Schedules.canonicalOccurrence(
                scheduleRow.occurrence!,
                dateOnly: overrideDateOnly,
              );
              final activity = Thread._fromStore(
                activity: activityRow,
                priority: priority,
                tags: result.readTableOrNull(tags),
                schedule: scheduleRow,
                active: activeIds.contains(activityRow.id),
                unreadComputed: unreadIds.contains(activityRow.id),
                linkSourceCreatedAt: linkSourceCreatedAt,
                rsvpInheritedFromSeries: false,
              );
              occurrences[overrideKey] = activity;
            }
          } catch (e, t) {
            log.warning(
              "Error generating occurrences for activity ${baseActivity.id}: $e\n$t",
            );
          }
          // Add generated occurrences to the activities list
          threadList.addAll(occurrences.values);
        } else {
          // No range provided - return the base recurring activity itself
          // This allows viewing/editing the recurrence template
          threadList.add(baseActivity);
        }
      }

      // Only create link schedule instances when a range is provided (agenda view).
      // Without a range (activity feed), the base thread already represents the activity.
      if (range != null && linkSchedules.isNotEmpty) {
        // Group link schedules by linkId so we can merge recurring base +
        // occurrence overrides per link (mirroring thread-level handling).
        final byLink = <String, List<ScheduleRow>>{};
        for (final ls in linkSchedules.values) {
          byLink.putIfAbsent(ls.linkId!.toString(), () => []).add(ls);
        }

        for (final linkGroup in byLink.values) {
          // Separate base recurring schedule from occurrence overrides.
          ScheduleRow? baseRecurring;
          final overrides = <ScheduleRow>[];
          for (final ls in linkGroup) {
            if (ls.recurrenceRule != null && ls.occurrence == null) {
              baseRecurring = ls;
            } else {
              overrides.add(ls);
            }
          }

          // If the base recurring schedule is archived, the entire series
          // was cancelled (e.g. a cancelled recurring Google Calendar event).
          // Skip materialising any instances — the thread itself still
          // appears in the activity feed via the non-range code path.
          if (baseRecurring != null && baseRecurring.archivedAt != null) {
            continue;
          }

          if (baseRecurring != null && range.bounded == true) {
            // Build a recurring link thread and generate occurrences into a
            // map keyed by occurrence string, then apply overrides.
            final baseThread = Thread._fromStore(
              activity: activityRow,
              priority: priority,
              schedule: baseRecurring,
              tags: tagsRow,
              active: activeIds.contains(activityRow.id),
              unreadComputed: unreadIds.contains(activityRow.id),
              isLinkScheduleInstance: true,
              linkSourceCreatedAt: linkSourceCreatedAt,
              rsvpInheritedFromSeries: false,
            );
            final occurrences = <String, Thread>{};
            try {
              for (final occ in baseThread.generateOccurrences(
                range.toBounded(),
              )) {
                occurrences[occ._schedule!.occurrence!] = occ;
              }
            } catch (e, t) {
              log.warning(
                "Error generating link schedule occurrences for activity ${baseActivity.id}: $e\n$t",
              );
            }
            // Apply occurrence overrides (replace matching generated entries).
            final overrideDateOnly = baseRecurring.startAt == null;
            for (final overrideRow in overrides) {
              if (overrideRow.occurrence != null) {
                final overrideKey = Schedules.canonicalOccurrence(
                  overrideRow.occurrence!,
                  dateOnly: overrideDateOnly,
                );
                occurrences[overrideKey] = Thread._fromStore(
                  activity: activityRow,
                  priority: priority,
                  schedule: overrideRow,
                  tags: tagsRow,
                  active: activeIds.contains(activityRow.id),
                  unreadComputed: unreadIds.contains(activityRow.id),
                  isLinkScheduleInstance: true,
                  linkSourceCreatedAt: linkSourceCreatedAt,
                  rsvpInheritedFromSeries: false,
                );
              }
            }
            threadList.addAll(
              occurrences.values.where((occ) => !occ.isDeclinedByUser),
            );
          } else {
            // Non-recurring link schedules: range-check and add individually.
            for (final linkScheduleRow in linkGroup) {
              if (linkScheduleRow.archivedAt != null) continue;
              final linkThread = Thread._fromStore(
                activity: activityRow,
                priority: priority,
                schedule: linkScheduleRow,
                tags: tagsRow,
                active: activeIds.contains(activityRow.id),
                unreadComputed: unreadIds.contains(activityRow.id),
                isLinkScheduleInstance: true,
                linkSourceCreatedAt: linkSourceCreatedAt,
                rsvpInheritedFromSeries: false,
              );
              if (linkThread.isDeclinedByUser) continue;
              if (range.bounded == true) {
                final r = range.toBounded();
                final linkStart =
                    linkScheduleRow.startAt ??
                    linkScheduleRow.startOn?.toDateTime();
                final linkEnd =
                    linkScheduleRow.endAt ??
                    linkScheduleRow.endOn?.toDateTime() ??
                    linkStart;
                if (linkStart != null) {
                  if (linkEnd != null &&
                      linkEnd.isBefore(r.start.toDateTime())) {
                    continue;
                  }
                  if (linkStart.isAfter(r.end.toDateTime())) continue;
                }
              }
              threadList.add(linkThread);
            }
          }
        }
      }
    }

    // Bulk-load occurrence-specific tags for generated recurring occurrences.
    // The main query joins tags via schedule occurrence, so tags saved on
    // generated occurrences (which have no stored schedule row) are invisible.
    final missingTagIds = <Uuid>{};
    for (final thread in threadList) {
      if (thread._tags == null && thread._schedule?.occurrence != null) {
        missingTagIds.add(thread.id);
      }
    }
    if (missingTagIds.isNotEmpty) {
      final tagTable = Store.get.threadTags;
      final tagQuery = Store.get.select(tagTable)
        ..where(
          (t) =>
              t.id.isIn(missingTagIds.map((id) => id.toBytes()).toList()) &
              t.occurrence.equals('').not(),
        );
      final tagResults = await tagQuery.get();

      if (tagResults.isNotEmpty) {
        // Index by (threadId, occurrence)
        final tagMap = <String, ThreadTagsRow>{};
        for (final row in tagResults) {
          tagMap['${row.id}:${row.occurrence}'] = row;
        }

        for (int i = 0; i < threadList.length; i++) {
          final thread = threadList[i];
          if (thread._tags == null && thread._schedule?.occurrence != null) {
            final key = '${thread.id}:${thread._schedule!.occurrence}';
            final tagRow = tagMap[key];
            if (tagRow != null) {
              threadList[i] = Thread._fromStore(
                activity: thread._thread,
                schedule: thread._schedule,
                tags: tagRow,
                priority: thread.priority,
                isLinkScheduleInstance: thread.isLinkScheduleInstance,
                rsvpInheritedFromSeries: thread.rsvpInheritedFromSeries,
                active: thread._active,
                unreadComputed: thread._unreadComputed,
                linkSourceCreatedAt: thread._linkSourceCreatedAt,
              );
            }
          }
        }
      }
    }

    return threadList;
  }

  static Map<Priority, List<Thread>> prioritize(
    List<Thread> threads, {
    Priority? context,
  }) {
    final Map<Priority, List<Thread>> threadsByPriority = {};
    for (final thread in threads) {
      threadsByPriority.putIfAbsent(thread.priority, () => []).add(thread);
    }

    final Map<Priority, List<Thread>> sortedThreadsByPriority = {};
    final priorities = threadsByPriority.keys.toList()
      ..sort((a, b) {
        if (context != null && a == context && b != context) return 1;
        if (context != null && a != context && b == context) return -1;
        return a.compareTo(b);
      });

    for (final priority in priorities) {
      final priorityThreads = threadsByPriority[priority]!;
      priorityThreads.sort();
      sortedThreadsByPriority[priority] = priorityThreads;
    }

    return sortedThreadsByPriority;
  }

  factory Thread({
    required Priority priority,
    String? title,
    String? preview,
    bool draft = false,
    DateTimeRange? at,
    DateRange? on,
    List<Note>? notes,

    /// Optional per-user thread-state fields. Production paths populate
    /// these via the Drift query in [Thread.watch] (the columns live
    /// directly on `threads`); exposed here so tests can construct a
    /// [Thread] in a specific state without going through [copyWith].
    bool active = false,
    bool? urgent,
    Order? stateOrder,
    Date? stateOn,
    DateTime? stateAt,
    DateTime? readAt,
    /// Team scope for the draft. Null = Personal. Carried through to the
    /// thread row and synced via `team_id`. Defaults null until the compose
    /// flow (Phase 5) sets it from the target picker.
    BigInt? teamId,
  }) {
    final now = Time.now();
    final threadId = Uuid.generate();
    final activity = ThreadRow(
      id: threadId,
      createdAt: now,
      updatedAt: now,
      priorityId: priority.id,
      draft: draft,
      title: title,
      preview: preview,
      unread: false,
      importance: 0,
      active: active,
      urgent: urgent,
      stateOrder: stateOrder,
      stateOn: stateOn,
      stateAt: stateAt,
      readAt: readAt,
      hasEmbedding: false,
      revoked: false,
      // Seed the topic routing key onto the draft thread so it inherits the
      // filter before the user types. When no explicit config.topic is set,
      // fall back to the priority id itself for non-root priorities, so
      // sibling threads filed in the same sub-priority share a topic filter
      // for classify_thread_for_user.
      //
      // Per-priority default contacts/groups/invite-emails are intentionally
      // NOT seeded here: the two-step target picker drives the thread's
      // roster, superseding per-focus default sharing.
      topic: priority.priorityConfig.topic ??
          (priority.path.isRoot ? null : priority.id.toString()),
      // Team scope for the draft (null = Personal until Phase 5 sets it from
      // the target picker). Round-trips through sync via `team_id`.
      teamId: teamId,
    );
    // Honor `at:` / `on:` by materializing the canonical schedule row.
    // DB constraint `schedule_at_xor_on` requires exactly one of the two,
    // so prefer `at` when both are passed.
    final schedule = (at != null || on != null)
        ? ScheduleRow(
            id: Uuid.generate(),
            updatedAt: now,
            threadId: threadId,
            startAt: at?.start,
            endAt: at?.end,
            startOn: at == null ? on?.start : null,
            endOn: at == null ? on?.end : null,
          )
        : null;
    return Thread._fromStore(
      activity: activity,
      priority: priority,
      schedule: schedule,
      notes: notes,
      activityDirty: true,
      activityRemoteDirty: true,
      scheduleDirty: true,
    );
  }

  Thread._fromStore({
    required ThreadRow activity,
    required this.priority,
    ScheduleRow? schedule,
    ThreadTagsRow? tags,
    List<Note>? notes,
    bool? active,
    bool? unreadComputed,
    this.isLinkScheduleInstance = false,
    this.rsvpInheritedFromSeries = false,
    DateTime? linkSourceCreatedAt,
    bool activityDirty = false,
    bool activityRemoteDirty = false,
    bool scheduleDirty = false,
    bool stateDirty = false,
  }) : _thread = activity,
       // ignore: prefer_initializing_formals
       _schedule = schedule,
       // ignore: prefer_initializing_formals
       _tags = tags,
       // ignore: prefer_initializing_formals
       _notes = notes,
       // ignore: prefer_initializing_formals
       _active = active,
       // ignore: prefer_initializing_formals
       _unreadComputed = unreadComputed,
       // ignore: prefer_initializing_formals
       _linkSourceCreatedAt = linkSourceCreatedAt,
       // ignore: prefer_initializing_formals
       _activityDirty = activityDirty,
       // ignore: prefer_initializing_formals
       _activityRemoteDirty = activityRemoteDirty,
       // ignore: prefer_initializing_formals
       _scheduleDirty = scheduleDirty,
       // ignore: prefer_initializing_formals
       _stateDirty = stateDirty {
    assert(
      priority.id == activity.priorityId,
      "Priority does not match activity",
    );
  }

  final ThreadRow _thread;
  final ScheduleRow? _schedule;
  final ThreadTagsRow? _tags;
  final List<Note>? _notes;
  final bool? _active;
  final bool? _unreadComputed;
  final DateTime? _linkSourceCreatedAt;
  final bool _activityDirty;

  /// Whether the activity row needs a remote push (vs local-only read-state update).
  final bool _activityRemoteDirty;
  final bool _scheduleDirty;

  /// Whether the per-user thread-state fields changed and need to be
  /// pushed via POST /sync/thread-state.
  final bool _stateDirty;

  /// Whether this instance represents a link schedule (event from a linked item).
  /// Link schedule instances appear at their event time and are not reorderable.
  final bool isLinkScheduleInstance;

  /// Whether the RSVP status shown on [_schedule] was inherited from the
  /// series row rather than set on this specific occurrence. Used by
  /// `rsvpTargetsOccurrence` to decide whether an RSVP change should target
  /// the series or the occurrence. Defaults to false. Set to true only by
  /// [loadRepresentativeForFeed] when it resolves a recurring event to a
  /// representative occurrence whose RSVP is a series-level copy.
  final bool rsvpInheritedFromSeries;

  final Priority priority;

  Uuid get id => _thread.id;
  bool get recurring =>
      _schedule?.recurrenceRule != null && _schedule?.occurrence == null;

  /// Per-user reorder position within the Doing section and within a
  /// single Scheduled day. Falls back to [Order.lowerBound] when no
  /// per-user state row has assigned one, so null-state threads sort
  /// first deterministically (matching the SQL `ORDER BY state_order
  /// ASC` behavior — SQLite defaults to NULLS FIRST). An earlier
  /// fallback of `Order.first()` returned a fresh `-now+random` value
  /// on every call, which made the [doing.sort] in priority.dart
  /// non-deterministic: a freshly computed `Order.between(null, X)`
  /// for a drag-to-top above a null-state thread would compare against
  /// a NEW `Order.first()` on the next sort pass, and because the new
  /// fallback's `-now` was strictly more negative (later wall-clock),
  /// the null-state thread re-sorted ahead of the dragged thread,
  /// snapping it back to 2nd position.
  Order get order => _thread.stateOrder ?? const Order(Order.lowerBound);

  /// Raw underlying per-user state order. Null when no per-user state row
  /// has assigned an order — exposed for callers that need to distinguish
  /// "no order set" from the [order] getter's deterministic fallback.
  Order? get rawStateOrder => _thread.stateOrder;
  DateTime get createdAt => _thread.createdAt;
  DateTime get updatedAt => _thread.updatedAt;
  DateTime? get archivedAt => _thread.archivedAt;
  bool get draft => _thread.draft;

  /// The actor credited with causing this thread's creation: the user's
  /// primary contact for app threads, the resolved external author for
  /// connector threads, and the twist for non-connection twist threads.
  /// Null on older / un-backfilled threads. Synced from `thread.author_id`.
  ActorId? get authorId => _thread.authorId;

  List<Uuid> get contacts => _thread.contacts ?? const [];

  /// Contacts who have been dropped from the active recipient set. They remain
  /// in [contacts] (for thread visibility) but are excluded from outbound
  /// defaults, the header AvatarGroup, and badge logic.
  List<Uuid> get droppedContacts => _thread.droppedContacts ?? const [];

  /// Active contacts: [contacts] minus [droppedContacts]. This is the set used
  /// for outbound defaults, badge superset logic, and the Shared section of
  /// the sharing modal.
  List<Uuid> get activeContacts {
    if (droppedContacts.isEmpty) return contacts;
    final droppedSet = droppedContacts.toSet();
    return contacts.where((c) => !droppedSet.contains(c)).toList();
  }

  /// Resolved sharing model for this thread, derived from the primary
  /// (earliest-created) link's [LinkTypeConfig.sharingModel]. Threads
  /// with no link default to [SharingModel.thread].
  ///
  /// The store layer caches links per thread, so this is a cheap
  /// in-memory lookup at the call site. Pass the list of links in
  /// rather than re-querying.
  static SharingModel resolveSharingModel(List<Link> links) {
    if (links.isEmpty) return SharingModel.thread;
    final primary = [...links]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final cfg = primary.first.getTypeConfig();
    return cfg?.sharingModel ?? SharingModel.thread;
  }

  /// Whether this is a "Plot thread" — one created by a user or a
  /// non-connection twist, as opposed to one a connector created via a link.
  /// Determined from the primary (earliest-created) link's creator: when that
  /// link was authored by a connection-source twist instance
  /// ([TwistInstance.isSource]) the thread originated from a connector and is
  /// not a Plot thread. Threads with no links, or whose primary link was
  /// authored by a user or a non-connection twist (e.g. Plot AI), are Plot
  /// threads.
  ///
  /// Until links load the list is empty, so this defaults to `true` (Plot
  /// thread) — the stable default that keeps Plot-only affordances (e.g.
  /// Rename) visible rather than flickering them in once links resolve.
  static bool isPlotThread(List<Link> links) {
    if (links.isEmpty) return true;
    final primary = [...links]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final creator = primary.first.createdBy;
    if (creator == null) return true;
    return !(TwistInstance.fromCache(creator)?.isSource ?? false);
  }

  /// Returns the link whose assignee should be shown in the thread row /
  /// unified header avatar slot, or null when the thread is not in
  /// "assignment mode".
  ///
  /// A thread is in assignment mode when its primary (earliest-created)
  /// link's [LinkTypeConfig] has BOTH `sharingModel == channel` AND
  /// `supportsAssignee == true`. Only the primary link participates; other
  /// qualifying links remain visible inside the thread page via the
  /// per-link assignee badge.
  static Link? resolvePrimaryAssignmentLink(List<Link> links) {
    final qualifying = links.where((l) {
      final cfg = l.getTypeConfig();
      return cfg?.sharingModel == SharingModel.channel &&
          cfg?.supportsAssignee == true;
    }).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return qualifying.isEmpty ? null : qualifying.first;
  }

  /// Label for the per-message recipient-change feed line in a message-mode
  /// thread. Compares this note's audience to the previous note's audience and
  /// describes the membership delta from the reader's perspective. Returns
  /// null when nothing changed (no line). Self (the viewer's contacts) is
  /// excluded from named lists. v1 covers membership changes only — role
  /// transitions ("Sam to BCC") are a tracked follow-up.
  static String? recipientChangeLabel({
    required Set<Uuid> previous,
    required Set<Uuid> current,
    required Set<Uuid> viewerContactIds,
    required String Function(Uuid) nameLookup,
  }) {
    final added = current.difference(previous).difference(viewerContactIds);
    final removed = previous.difference(current).difference(viewerContactIds);
    if (added.isEmpty && removed.isEmpty) return null;

    final currentOthers = current.difference(viewerContactIds);

    String names(Iterable<Uuid> ids) {
      final list = ids.map(nameLookup).toList();
      if (list.length == 1) return list[0];
      if (list.length == 2) return '${list[0]} and ${list[1]}';
      if (list.length == 3) return '${list[0]}, ${list[1]} and ${list[2]}';
      return '${list[0]}, ${list[1]} +${list.length - 2}';
    }

    if (removed.isNotEmpty && added.isEmpty) {
      if (currentOthers.length == 1 && removed.length >= 2) {
        return 'Dropped everyone except ${names(currentOthers)}';
      }
      return 'Dropped ${names(removed)}';
    }
    if (added.isNotEmpty && removed.isEmpty) {
      return 'Added ${names(added)}';
    }
    return 'Added ${names(added)}, dropped ${names(removed)}';
  }

  /// Union of `access_contacts` across all of a thread's notes, plus
  /// each note's author. Used by the message-mode sharing modal to
  /// populate the Dropped section and the re-add suggestion source.
  ///
  /// Returns a `Set<Uuid>` — order doesn't matter; the modal sorts for
  /// display.
  static Set<Uuid> historicalParticipants(List<Note> notes) {
    final out = <Uuid>{};
    for (final note in notes) {
      out.add(note.authorId.value);
      final access = note.accessContacts;
      if (access != null) {
        for (final actor in access) {
          out.add(actor.value);
        }
      }
    }
    return out;
  }

  /// Participants of the most recent note (its author + access_contacts).
  /// Used as the default reply audience for message-mode threads — "a
  /// reasonable assumption of the recipients at that point in the thread."
  /// Returns an empty set when there are no notes (callers fall back to
  /// thread.contacts). Order is not significant; callers dedupe.
  static Set<ActorId> latestNoteAudience(List<Note> notes) {
    if (notes.isEmpty) return const {};
    final latest = notes.reduce(
      (a, b) => b.sourceCreatedAt.isAfter(a.sourceCreatedAt) ? b : a,
    );
    return {
      latest.authorId,
      ...?latest.accessContacts,
    };
  }

  /// Per-contact metadata (role assignments, etc) keyed by contact uuid
  /// (string). Empty when no roles are set; contacts not in the map use the
  /// link type's default role. See `ContactRoleConfig` and
  /// `thread.contact_meta` on the server.
  Map<String, dynamic> get contactMeta =>
      (_thread.contactMeta ?? const {}).cast<String, dynamic>();
  List<Uuid> get groups => _thread.groups ?? const [];
  String? get topic => _thread.topic;

  /// Team scope for this thread (`thread.team_id` on the server). Null when
  /// the thread is Personal. Server-immutable after create.
  BigInt? get teamId => _thread.teamId;
  /// Pending email invitations that haven't been synced yet.
  List<String> get inviteEmails {
    final raw = _thread.inviteEmails;
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  DateTime? get lastNoteCreatedAt => _thread.lastNoteCreatedAt;
  DateTime? get lastNoteSourceCreatedAt => _thread.lastNoteSourceCreatedAt;
  RecurrenceRule? get recurrenceRule => _schedule?.recurrenceRule;
  List<DateTime>? get recurrenceExdates => _schedule?.recurrenceExdates;
  Map<Tag, List<ActorId>> get tags => {
    ...Map.fromEntries(
      [
        Tag.todo,
        Tag.archived,
        Tag.private,
      ].where((tag) => hasTag(tag)).map((tag) => MapEntry(tag, [Base.actorId])),
    ),
    // Linked-contact aliases collapse to the user's canonical actor.
    for (final entry in (_tags?.tags ?? const {}).entries)
      entry.key: Actor.dedupeByIdentity(entry.value),
  };

  /// Whether this thread is in the per-tab "active bucket" computed by the
  /// SQL `is_active` column (today vs scheduled, etc). Set by the per-tab
  /// query path; null elsewhere. Kept as `inActiveBucket` to avoid clashing
  /// with the per-user `active` state boolean exposed on the thread row.
  bool get inActiveBucket => _active ?? false;

  /// Returns true if this activity is unread (considering local overrides)
  bool get unread {
    final computed = _unreadComputed;
    final stored = _thread.unread;
    final result = computed ?? stored;

    return result;
  }

  DateTime? get readAt => _thread.readAt;

  /// The content timestamp — GREATEST(lastNoteSourceCreatedAt, createdAt).
  /// Used as the read_at value when the user reads this thread.
  DateTime get contentTimestamp => lastNoteSourceCreatedAt ?? createdAt;

  /// Derived "action type" string for backwards-compatible call sites that
  /// still want a single-valued summary. Returns 'active' when the thread is
  /// on the user's Doing list, or null when it has no per-user state. Prefer
  /// the `active` boolean getter directly.
  String? get actionType {
    if (_thread.active) return 'active';
    return null;
  }

  /// Backwards-compat alias for older call sites. Equivalent to [actionType].
  String? get scheduleAction => actionType;

  /// True when the user should be notified immediately rather than
  /// waiting for the next see-within window.
  bool get urgent => _thread.urgent ?? false;

  int get importance => _thread.importance;

  String? get title => _thread.title;
  String? get preview => _thread.preview;
  String? get icon => _thread.icon;
  ActorId? get assigneeId => _thread.assigneeId;
  bool get hasEmbedding => _thread.hasEmbedding;

  /// Anchor for the "Skip active for threads like this" mute rule. Non-null
  /// on threads the rule swept (and on the seed itself, where it equals the
  /// thread's own id). Null when the thread is not muted.
  ThreadId? get muteByThreadId => _thread.muteByThreadId;

  /// True if the current user only sees this thread via an announce-typed
  /// group they don't admin (i.e. not a direct contact, not a member of any
  /// non-announce group on the thread). Read-only viewers cannot edit
  /// thread metadata, may only post private notes, and archive per-user.
  bool get isReadOnly {
    final selfIds = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    if (contacts.any(selfIds.contains)) return false;
    for (final groupId in groups) {
      final g = Group.fromCache(groupId);
      if (g == null) continue;
      if (g.type == 'announce') {
        if (g.isAdmin) return false;
      } else if (g.isMember) {
        return false;
      }
    }
    return true;
  }

  /// Resolves a thread icon identifier to a logo URL and fallback icon.
  static ({String? logoUrl, String? logoDarkUrl, IconData fallbackIcon})
  resolveIcon(String? icon) {
    if (icon == null) {
      return (logoUrl: null, logoDarkUrl: null, fallbackIcon: PlotIcon.notes);
    }
    if (icon.startsWith('http')) {
      return (logoUrl: icon, logoDarkUrl: null, fallbackIcon: PlotIcon.link);
    }
    if (icon == 'link') {
      return (logoUrl: null, logoDarkUrl: null, fallbackIcon: PlotIcon.link);
    }
    if (icon.startsWith('twist:')) {
      final twistId = BigInt.tryParse(icon.substring(6));
      if (twistId != null) {
        final pt = TwistInstance.findByTwistId(twistId);
        if (pt?.logoUrl != null) {
          return (
            logoUrl: pt!.logoUrl,
            logoDarkUrl: pt.logoUrlDark,
            fallbackIcon: PlotIcon.twist,
          );
        }
      }
      return (logoUrl: null, logoDarkUrl: null, fallbackIcon: PlotIcon.twist);
    }
    if (icon.startsWith('connector:')) {
      final parts = icon.substring(10).split(':');
      final twistId = BigInt.tryParse(parts[0]);
      final type = parts.length > 1 ? parts[1] : null;
      if (twistId != null) {
        final pt = TwistInstance.findByTwistId(twistId);
        if (pt != null) {
          if (type != null) {
            // Check twist-level linkTypes first
            final config = pt.parsedLinkTypes
                ?.where((c) => c.type == type)
                .firstOrNull;
            if (config?.logo != null) {
              return (
                logoUrl: config!.logo,
                logoDarkUrl: config.logoDark,
                fallbackIcon: PlotIcon.link,
              );
            }
            // Fall back to channel linkTypes (for no-provider connectors
            // like Attio where linkTypes are only stored per-channel)
            final channelConfig = Channel.findBySource(
              pt.id,
            )?.parsedLinkTypes?.where((c) => c.type == type).firstOrNull;
            if (channelConfig?.logo != null) {
              return (
                logoUrl: channelConfig!.logo,
                logoDarkUrl: channelConfig.logoDark,
                fallbackIcon: PlotIcon.link,
              );
            }
          }
          if (pt.logoUrl != null) {
            return (
              logoUrl: pt.logoUrl,
              logoDarkUrl: pt.logoUrlDark,
              fallbackIcon: PlotIcon.link,
            );
          }
        }
      }
      return (logoUrl: null, logoDarkUrl: null, fallbackIcon: PlotIcon.link);
    }
    final subType = ThreadSubType.fromIcon(icon);
    if (subType != null) {
      return (logoUrl: null, logoDarkUrl: null, fallbackIcon: subType.icon);
    }
    return (logoUrl: null, logoDarkUrl: null, fallbackIcon: PlotIcon.notes);
  }

  List<Note>? get notes => _notes;

  /// Returns the first note if notes are loaded
  Note? get firstNote => notes?.firstOrNull;

  /// Returns true if this activity has any notes
  bool get hasNotes => notes != null && notes!.isNotEmpty;

  String get displayTitle {
    if (title != null) return title!;
    final derived = _titleFromContent(preview);
    if (derived != null) return derived;
    return draft ? '🤷' : 'Untitled';
  }

  String? get displayPreview {
    if (title != null) {
      // Normalise to a single line so legacy multi-line previews (bullet
      // lists, headings) render correctly inline beside the title.
      return createPreviewFromMarkdown(preview);
    }
    if (preview == null) return null;
    final derivedTitle = _titleFromContent(preview);
    if (derivedTitle == null) return null;
    return _remainderPreview(preview!, derivedTitle);
  }

  /// Removes zero-width / invisible format characters. Newsletters pad their
  /// preheader with these (e.g. U+034F combining grapheme joiner + U+200B
  /// zero-width space, repeated) to push later content out of the inbox
  /// snippet. They are not matched by `\s`, so they survive whitespace collapse
  /// and render as a long run of blank space before the truncation ellipsis.
  /// Keep in sync with `stripMarkdown` in
  /// `workers/api/src/twist/tools/plot/thread-helpers.ts`.
  static final RegExp _invisibleChars = RegExp(
    r'[\u00AD\u034F\u061C\u200B-\u200F\u2060-\u2064\u206A-\u206F\uFEFF]',
  );

  static String _stripMarkdownAndInvisible(String input) =>
      input.removeMarkdown(replaceLinksWithURL: false).replaceAll(_invisibleChars, '');

  /// Derives a display title from content (preview or note body).
  /// Strips markdown, takes the first line, truncates at word boundary if > 60 chars.
  static String? _titleFromContent(String? content) {
    if (content == null || content.trim().isEmpty) return null;
    final stripped = _stripMarkdownAndInvisible(content);
    final firstLine = stripped.split('\n').first.trim();
    if (firstLine.isEmpty) return null;
    if (firstLine.length <= 60) return firstLine;
    final lastSpace = firstLine.lastIndexOf(' ', 60);
    if (lastSpace > 0) {
      return '${firstLine.substring(0, lastSpace)}\u2026';
    }
    return '${firstLine.substring(0, 59)}\u2026';
  }

  /// Normalises markdown into a single-line preview string suitable for
  /// inline display next to a title. Mirrors `createPreviewFromMarkdown`
  /// in `workers/api/src/twist/tools/plot/thread-helpers.ts` — keep in
  /// sync so client and server agree on what `thread.preview` contains.
  static String? createPreviewFromMarkdown(String? markdown) {
    if (markdown == null || markdown.isEmpty) return null;
    var preview = _stripMarkdownAndInvisible(markdown);
    preview = preview.replaceAll(RegExp(r'https?://[^\s)>\]]+'), '');
    preview = preview.replaceAll(RegExp(r'\n+'), ' / ');
    preview = preview.replaceAll(RegExp(r'\s+'), ' ');
    preview = preview.replaceAll(RegExp(r'(\s+/\s*|\s*/\s+)+'), ' / ');
    preview = preview.replaceAll(RegExp(r'^[\s/]+|[\s/]+$'), '');
    if (preview.length > 100) {
      preview = '${preview.substring(0, 100).trim()}…';
    }
    return preview.isEmpty ? null : preview;
  }

  /// Returns the portion of preview after the derived title.
  static String? _remainderPreview(String preview, String derivedTitle) {
    String prefix = derivedTitle;
    if (prefix.endsWith('\u2026')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    final stripped = _stripMarkdownAndInvisible(preview);
    final idx = stripped.indexOf(prefix);
    if (idx < 0) return null;
    var remainder = stripped.substring(idx + prefix.length).trim();
    remainder = remainder.replaceAll(RegExp(r'^[\s/]+'), '').trim();
    return remainder.isEmpty ? null : remainder;
  }

  DateTimeRange? get at {
    if (isLinkScheduleInstance) {
      if (_schedule?.startAt != null) {
        final start = _schedule!.startAt!;
        final endAt =
            _schedule.endAt ??
            (_schedule.duration != null
                ? start.add(_schedule.duration!)
                : start);
        return DateTimeRange(start, endAt);
      }
      return on?.toDateTimeRange();
    }
    return (_schedule?.startAt != null
            ? DateTimeRange(_schedule!.startAt!, _schedule.endAt)
            : null) ??
        (_thread.stateAt != null && active
            ? DateTimeRange(_thread.stateAt!, null)
            : null) ??
        on?.toDateTimeRange();
  }

  DateRange? get on {
    if (isLinkScheduleInstance) {
      return _schedule?.startOn != null
          ? CustomDateRange(_schedule!.startOn!, _schedule.endOn)
          : null;
    }
    return (_schedule?.startOn != null
            ? CustomDateRange(_schedule!.startOn!, _schedule.endOn)
            : null) ??
        (_thread.stateOn != null &&
                active &&
                _thread.stateOn != Thread.todoNowDate
            ? CustomDateRange(_thread.stateOn!, null)
            : null);
  }

  Duration? get duration {
    // Per-user state has no duration; events on the shared schedule do.
    return _schedule?.duration ?? on?.duration ?? at?.duration;
  }

  DateTime get agendaAt {
    if (isLinkScheduleInstance) {
      // Link schedule instances always appear at their schedule time
      return at?.start ?? on?.start?.toDateTime() ?? createdAt;
    }
    if (todo) {
      // Per-user state date takes priority (explicit user override via reorder).
      final schedDate =
          _thread.stateOn?.toDateTime() ??
          pinnedAfterTime ??
          at?.start ??
          on?.start?.toDateTime();
      if (schedDate == null || schedDate.toDate().isBefore(Date.today())) {
        return Date.today().toDateTime();
      }
      return schedDate;
    }
    return at?.start ??
        on?.start?.toDateTime() ??
        _thread.lastNoteSourceCreatedAt ??
        createdAt;
  }

  /// True when this active thread would only appear in today's agenda
  /// via the [agendaAt] collapse-to-today fallback — i.e. it has no
  /// shared/calendar schedule anchoring it, and no explicit non-sentinel
  /// per-user date. The agenda's explicit-only model drops these;
  /// active threads remain accessible from the priority's Active list.
  ///
  /// Keeps a thread when ANY of:
  ///   - It has a shared schedule ([ScheduleRow.startAt] or `startOn`)
  ///     today or later — a real calendar event.
  ///   - Its per-user `state_on` is a real date (not the `todoNowDate`
  ///     "anytime today" sentinel) AND today or later.
  ///
  /// Drops everything else, including:
  ///   - Active threads with no schedule at all.
  ///   - Per-user `state_at` pins without a shared schedule — these
  ///     surfaced [at] from `stateAt` rather than a real calendar slot,
  ///     so they're implicit todos, not events.
  ///   - `state_on = todoNowDate` ("anytime today" sentinel).
  ///   - Past shared schedules and past `state_on` dates that the
  ///     collapse-to-today fallback would forward.
  bool get isAgendaAtAutoForwarded {
    if (isLinkScheduleInstance) return false;
    if (!todo) return false;
    final sharedStart = _schedule?.startAt;
    if (sharedStart != null && !sharedStart.toDate().isBefore(Date.today())) {
      return false;
    }
    final sharedStartOn = _schedule?.startOn;
    if (sharedStartOn != null && !sharedStartOn.isBefore(Date.today())) {
      return false;
    }
    final stateOn = _thread.stateOn;
    if (stateOn != null &&
        stateOn != Thread.todoNowDate &&
        !stateOn.isBefore(Date.today())) {
      return false;
    }
    return true;
  }

  /// Original schedule date for todo sorting. Unlike agendaAt, this preserves
  /// past dates so that todos from different days maintain their relative order
  /// when they all appear as "current".
  DateTime get todoSortDate {
    return _thread.stateOn?.toDateTime() ??
        pinnedAfterTime ??
        at?.start ??
        on?.start?.toDateTime() ??
        createdAt;
  }

  /// Compare todos by original schedule date first, then by order.
  ///
  /// **Used by the agenda**, where each day is its own visible section so
  /// the date-then-order sort produces a coherent within-day ordering. Do
  /// **not** use this in the Activity tab's Today section — that section
  /// flattens "anytime today" todos (`startOn = todoNowDate (1970)`),
  /// past-overdue todos, and today's elapsed events into a single list,
  /// so the date dimension would silently bucket the rows into 1970 / past
  /// / today groups and break drag-and-drop placement (the user drops
  /// after the visible last row, but the dragged row's
  /// `startOn = todoNowDate` makes it sort with the 1970 group). Use
  /// [activityCompareTo] instead.
  int todoCompareTo(Thread other) {
    final dateComp = todoSortDate.compareTo(other.todoSortDate);
    if (dateComp != 0) return dateComp;
    return order.compareTo(other.order);
  }

  /// Compare todos for the Activity tab by `userSchedule.order` alone.
  ///
  /// The Activity tab's Today section is a single visible list that mixes
  /// "anytime today" todos (`startOn = todoNowDate`), past-overdue todos,
  /// and today's elapsed events. The user reorders this list with
  /// drag-and-drop, which writes `userSchedule.order` via
  /// [Order.between] — date is not part of the drop semantics and the
  /// section has no per-date sub-headers, so order alone is the natural
  /// sort key. Sorting by [todoCompareTo] (date-then-order) instead would
  /// silently bucket rows by date and place a freshly-dropped row in the
  /// wrong group regardless of the chosen order.
  int activityCompareTo(Thread other) => order.compareTo(other.order);

  /// Timestamp for activity feed ordering and bucket headers.
  /// GREATEST(lastNoteSourceCreatedAt, linkSourceCreatedAt, bumpedAt, pastScheduleEnd),
  /// falling back to createdAt when all are null.
  DateTime get activityAt {
    DateTime? best = _thread.lastNoteSourceCreatedAt;
    if (_linkSourceCreatedAt != null &&
        (best == null || _linkSourceCreatedAt.isAfter(best))) {
      best = _linkSourceCreatedAt;
    }
    if (bumpedAt != null && (best == null || bumpedAt!.isAfter(best))) {
      best = bumpedAt;
    }
    // Include past event end time
    final schedEnd = _lastPastOccurrenceEnd;
    if (schedEnd != null && (best == null || schedEnd.isAfter(best))) {
      best = schedEnd;
    }
    return best ?? createdAt;
  }

  /// End time of the most recent past occurrence, for activity feed sorting.
  /// For non-recurring events, uses the schedule end time directly.
  /// For recurring events, computes the last occurrence that has ended before now.
  DateTime? get _lastPastOccurrenceEnd {
    if (_schedule == null) return null;

    final now = Time.now();
    // A cancelled (archived) recurring schedule still has an RRULE, so naively
    // iterating it would keep producing today's occurrence forever. Cap the
    // search at the cancellation time so cancelled events don't appear as
    // ongoing activity.
    final archived = _schedule.archivedAt;
    final upper = archived != null && archived.isBefore(now) ? archived : now;

    if (!recurring) {
      // Non-recurring: use the schedule end time directly
      final end = _schedule.endAt ?? _schedule.endOn?.toDateTime();
      return (end != null && end.isBefore(upper)) ? end : null;
    }

    // Recurring: find the last occurrence that has ended before the upper bound
    final start = (at?.start ?? on?.start?.toDateTime());
    if (start == null || recurrenceRule == null) return null;

    try {
      final instances = recurrenceRule!.getInstances(
        start: start.copyWith(isUtc: true),
        after: start.copyWith(isUtc: true),
        includeAfter: true,
        before: upper.copyWith(isUtc: true),
      );

      DateTime? lastInstance;
      for (final instance in instances) {
        lastInstance = instance.copyWith(isUtc: false);
      }

      if (lastInstance != null && duration != null) {
        final end = lastInstance.add(duration!);
        if (end.isBefore(upper)) return end;
      }
    } catch (_) {
      // Silently handle invalid RRULEs
    }

    return null;
  }

  /// Whether the user is actively acting on this thread now (Doing section
  /// in the unified feed).
  ///
  /// `readAt` is the user's read marker, not a "finished" marker — finishing
  /// flips `active` itself off (via the `todo: false` branch in copyWith).
  /// Reading or reordering an active thread must leave it in Doing.
  bool get active => _thread.active;

  /// Backwards-compat alias: a thread is `todo` when the user has flagged
  /// it active and hasn't finished it.
  bool get todo => active;

  /// Canonical "is this thread in the user's Doing list?" predicate,
  /// factored out so the Dart [active] getter and any SQL clause that
  /// filters Doing share a single source of truth. Just the `active`
  /// boolean — `read_at` is the read marker, not a "finished" marker.
  static bool isActive({required bool active}) => active;

  /// Backwards-compat alias for older call sites.
  static bool isTodo({required bool active}) => isActive(active: active);

  /// Legacy helper retained for the predicate-matrix test fixtures. Mirrors
  /// the old schedule-shape rule: a user has a todo when the per-user
  /// schedule row exists, isn't archived, and has either a start date or
  /// start time. The new per-user state model expresses the same idea
  /// through the [active] boolean.
  @Deprecated('Use Thread.isActive (booleans) for new code.')
  static bool isTodoUserSchedule({
    required Object? userScheduleId,
    required DateTime? archivedAt,
    required Date? startOn,
    required DateTime? startAt,
  }) {
    return userScheduleId != null &&
        archivedAt == null &&
        (startOn != null || startAt != null);
  }

  /// Returns the pinned-after time for an active thread that was dragged
  /// after an event. A thread is "pinned" when it has a per-user `stateAt`
  /// but no real `stateOn` (null or epoch sentinel). Returns null for
  /// regular active/scheduled threads.
  DateTime? get pinnedAfterTime {
    final stateAt = _thread.stateAt;
    if (stateAt == null) return null;
    final stateOn = _thread.stateOn;
    if (stateOn == null || stateOn == Thread.todoNowDate) return stateAt;
    return null;
  }

  /// Whether this active thread is pinned after a specific event.
  bool get isPinnedTodo => pinnedAfterTime != null;

  /// Doing section: active and not scheduled for the future.
  bool get isActiveThread => active && !isFuture;

  /// Scheduled section (per-day): active with a future user-schedule date.
  bool get isScheduledThread => active && isFuture;

  /// Unread row visible in the Updates section. Always rendered for any
  /// unread thread regardless of whether it's also in Doing or Scheduled
  /// (the Updates section explicitly duplicates).
  bool get isUnreadOnly => unread;

  /// Activity section (tail of history): not unread and not active.
  bool get isInactiveThread => !active && !unread;

  DateTime? get bumpedAt => _thread.bumpedAt;

  bool get isPast =>
      at?.end?.isBefore(Time.now()) == true ||
      on?.end?.isBefore(Date.today()) == true;
  bool get isFuture {
    if (isLinkScheduleInstance) {
      // Icon based on per-user state only, not the link schedule's date
      if (_thread.stateOn != null) {
        return _thread.stateOn!.isAfter(Date.today());
      }
      return false; // No user date = not future = shows todo icon
    }
    // For todos, check the per-user state date first (matches agendaAt
    // logic) so the icon is consistent with the date the thread appears
    // under.
    if (todo && _thread.stateOn != null) {
      return _thread.stateOn!.isAfter(Date.today());
    }
    if (todo && pinnedAfterTime != null) {
      return pinnedAfterTime!.toDate().isAfter(Date.today());
    }
    return on?.start?.isAfter(Date.today()) == true ||
        (on == null && at?.start?.toDate().isAfter(Date.today()) == true);
  }

  bool get assignedToOther => false;

  /// Whether this thread has a link-based schedule (event from a linked item)
  /// attached as its effective schedule. True when the base `_schedule` came
  /// from a link rather than the thread itself.
  bool get hasLinkSchedule => _schedule?.linkId != null;

  String? get occurrence => _schedule?.occurrence;
  Uuid? get scheduleId => _schedule?.id;

  /// When non-null, this thread was merged into the referenced target and
  /// is archived. Discoverable via the back-reference column.
  ThreadId? get mergedIntoThreadId => _thread.mergedIntoThreadId;

  /// The current user's RSVP status on this schedule ('attend', 'skip', or null).
  String? get currentUserRsvp => _schedule?.currentUserStatus;

  /// Whether the current user has effectively declined this schedule.
  /// True when at least one of the user's contacts has 'skip' and none have 'attend'.
  bool get isDeclinedByUser {
    final contacts = scheduleContacts;
    if (contacts.isEmpty) return false;
    if (!Base.signedIn) return false;
    final userId = Base.userId.toString();
    String? best;
    for (final c in contacts) {
      if (c.contactUserId == userId) {
        if (c.status == 'attend') return false;
        if (c.status == 'skip') best = 'skip';
      }
    }
    return best == 'skip';
  }

  /// Parsed schedule contacts, excluding archived contacts.
  List<ScheduleContact> get scheduleContacts {
    final contactsJson = _schedule?.contacts;
    if (contactsJson == null || contactsJson.isEmpty) return [];
    try {
      final List<dynamic> parsed = jsonDecode(contactsJson) as List<dynamic>;
      return parsed
          .map((e) => ScheduleContact.fromJson(e as Map<String, dynamic>))
          .where(
            (c) => c.status != null || c.role != null,
          ) // filter out empty/archived
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Whether this event has other attendees besides the current user.
  bool get hasOtherAttendees => scheduleContacts.length > 1;

  /// RSVP counts from non-archived contacts.
  ({int attend, int skip, int undecided}) get rsvpCounts {
    final contacts = scheduleContacts;
    int attend = 0, skip = 0, undecided = 0;
    for (final c in contacts) {
      switch (c.status) {
        case 'attend':
          attend++;
        case 'skip':
          skip++;
        default:
          undecided++;
      }
    }
    return (attend: attend, skip: skip, undecided: undecided);
  }

  /// Returns a new Thread with the RSVP status updated for the current user.
  Thread withRsvpStatus(String? newStatus) {
    final schedule = _schedule;
    if (schedule == null) return this;

    // Parse existing contacts
    List<Map<String, dynamic>> contacts;
    try {
      contacts = (jsonDecode(schedule.contacts ?? '[]') as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      contacts = [];
    }

    // Find current user's entries and update status (all contacts for this user)
    final userId = Base.userId.toString();
    bool found = false;
    for (int i = 0; i < contacts.length; i++) {
      if (contacts[i]['contact_user_id'] == userId) {
        contacts[i] = {...contacts[i], 'status': newStatus};
        found = true;
      }
    }
    if (!found) {
      // Add a new entry for the current user
      contacts.add({
        'contact_id': Base.actorId.toString(),
        'contact_user_id': userId,
        'status': newStatus,
      });
    }

    final updatedSchedule = schedule.copyWith(
      contacts: Value(jsonEncode(contacts)),
      currentUserStatus: Value(newStatus),
    );

    return Thread._fromStore(
      activity: _thread,
      schedule: updatedSchedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      scheduleDirty: true,
    );
  }

  static const separator = ' › ';

  /// Returns a new Thread with the given thread-state fields applied to
  /// the thread row, preserving everything else. Marks the result as
  /// state-dirty so [save] pushes via /sync/thread-state.
  Thread _withThreadState(ThreadRow updated) {
    return Thread._fromStore(
      activity: updated,
      schedule: _schedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      activityDirty: true,
      stateDirty: true,
    );
  }

  /// Returns a copy with the per-user active flag cleared so the thread
  /// no longer renders in Doing. No-op when there's no per-user state to
  /// clear.
  Thread withScheduleArchived() {
    if (!_thread.active) return this;
    final now = DateTime.now();
    return _withThreadState(
      _thread.copyWith(
        active: false,
        stateOn: const Value(null),
        stateAt: const Value(null),
        updatedAt: now,
      ),
    );
  }

  /// Returns a copy with the per-user state restored so the thread renders
  /// as a regular active item in the unified feed. Mirrors what
  /// `disassociate(order, date)` will persist so the optimistic UI shows
  /// the thread back the instant the user clicks "Remove from event"
  /// instead of letting it vanish while the DB write resolves.
  Thread withScheduleRestored({required Order order, Date? date}) {
    final now = DateTime.now();
    return _withThreadState(
      _thread.copyWith(
        active: true,
        stateOrder: Value(order),
        stateOn: Value(date ?? Thread.todoNowDate),
        stateAt: const Value(null),
        updatedAt: now,
      ),
    );
  }

  /// Returns a copy in the "active" state (todo with `todoNowDate` sentinel).
  /// Preserves the existing state_order if [order] is null. When the thread
  /// was unread, marks it acknowledged (so the user isn't shown an unread
  /// dot on something they're already acting on). Used by the Activity-tab
  /// drag dispatcher when a thread is dropped in the Today section.
  Thread asActiveToday({Order? order}) {
    final effectiveOrder = order ?? _thread.stateOrder ?? Order.first();
    final restored = withScheduleRestored(order: effectiveOrder);
    if (!unread) return restored;
    return restored.copyWith(unread: false, readAt: Value(contentTimestamp));
  }

  /// Returns a copy in the "scheduled" state for [date]. Sets the
  /// per-user state's `stateOn` to the given date, clears time fields,
  /// and (when unread) marks the thread acknowledged since the user has
  /// committed it to a future day.
  Thread asScheduled(Date date, {Order? order}) {
    final effectiveOrder = order ?? _thread.stateOrder ?? Order.first();
    final restored = withScheduleRestored(order: effectiveOrder, date: date);
    if (!unread) return restored;
    return restored.copyWith(unread: false, readAt: Value(contentTimestamp));
  }

  /// Returns a copy in the "new (unread-only)" state — flips `unread` to
  /// true and marks any per-user state as read so the thread isn't
  /// classed as active or scheduled.
  Thread asUnread() {
    final hasState = _thread.active;
    final base = hasState ? withScheduleArchived() : this;
    return base.copyWith(unread: true, readAt: const Value(null));
  }

  /// Returns a copy positioned in the unread cluster at the top of the
  /// Doing section. Marks unread and sets the bucket fields (urgent,
  /// importance) plus stateOrder so the thread sorts to a specific slot
  /// among the other unread threads. Preserves any existing active /
  /// scheduled state so when the thread is later marked read it falls
  /// back to its natural section (Doing-active, Scheduled day, or
  /// Activity).
  Thread asUnreadInDoing({
    required Order order,
    required bool urgent,
    required int importance,
  }) {
    return _withThreadState(
      _thread.copyWith(
        unread: true,
        readAt: const Value(null),
        urgent: Value(urgent ? true : null),
        importance: importance,
        stateOrder: Value(order),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Returns a copy in the "inactive (done)" state. The
  /// `copyWith(todo: false, bump: true)` path archives any user schedule,
  /// sets `unread=false` and `readAt`, and bumps `bumpedAt` so the
  /// thread surfaces at the top of the Done section in the activity feed.
  Thread asInactive() => copyWith(todo: false, bump: true);

  /// Returns a copy with [isLinkScheduleInstance] set to false.
  /// Used for optimistic insertion of the base todo duplicate when starting
  /// a link schedule thread.
  Thread toBaseTodo() {
    return Thread._fromStore(
      activity: _thread,
      schedule: _schedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: false,
      rsvpInheritedFromSeries: false,
    );
  }

  /// Reorder this thread. Updates the per-user state_order on the thread row.
  Thread reorder(Order order) {
    if (!_thread.active) {
      log.warning('[reorder] "$title" has no per-user state — cannot reorder');
      return this;
    }
    final previous = _thread.stateOrder?.value;
    final result = _withThreadState(
      _thread.copyWith(stateOrder: Value(order), updatedAt: DateTime.now()),
    );
    log.info('[reorder] "$title" order: $previous -> ${order.value}');
    return result;
  }

  /// Reorder this thread to a different day. Updates order AND the
  /// per-user `stateOn` field.
  /// [date] null → sets epoch sentinel (Now/current todo).
  /// [date] someDate → schedules for that date, clears time fields.
  Thread reorderTo(Order order, {required Date? date}) {
    if (!_thread.active) {
      log.warning(
        '[reorderTo] "$title" has no per-user state — cannot reorder',
      );
      return this;
    }
    final previousOrder = _thread.stateOrder?.value;
    final previousOn = _thread.stateOn;
    final result = _withThreadState(
      _thread.copyWith(
        stateOrder: Value(order),
        stateOn: Value(date ?? Thread.todoNowDate),
        stateAt: const Value(null),
        updatedAt: DateTime.now(),
      ),
    );
    log.info(
      '[reorderTo] "$title" order: $previousOrder -> ${order.value} '
      'date: $previousOn -> $date',
    );
    return result;
  }

  /// Pin this todo after a specific event. Sets stateAt = event end
  /// time and clears stateOn so the todo appears after that event on
  /// today.
  Thread reorderToAfterEvent(Order order, {required DateTime eventEndTime}) {
    if (!_thread.active) {
      log.warning(
        '[reorderToAfterEvent] "$title" has no per-user state — cannot reorder',
      );
      return this;
    }
    final previousOrder = _thread.stateOrder?.value;
    final result = _withThreadState(
      _thread.copyWith(
        stateOrder: Value(order),
        stateAt: Value(eventEndTime),
        stateOn: const Value(null),
        updatedAt: DateTime.now(),
      ),
    );
    log.info(
      '[reorderToAfterEvent] "$title" order: $previousOrder -> ${order.value} '
      'pinned after: $eventEndTime',
    );
    return result;
  }

  /// Associate this thread with a parent event thread.
  /// Pure association op: only writes a `thread_association` row; the
  /// per-user schedule is left alone so "associated to event" and
  /// "on personal agenda" stay independent. Callers that want the
  /// classic "moved under the event, off the agenda" UX (e.g. dropping
  /// onto an event header in the agenda drag-drop) should also call
  /// [withScheduleArchived().save()] explicitly.
  Future<void> associateWith({
    required Uuid parentThreadId,
    required Order order,
  }) async {
    log.info(
      '[associateWith] "$title" -> parent=$parentThreadId order=${order.value}',
    );

    // Archive any existing active association for this child thread
    // (a child can only be associated with one parent at a time).
    final existing =
        await (Store.get.select(Store.get.threadAssociations)
              ..where((t) => t.childThreadId.equals(id.toBytes()))
              ..where((t) => t.archivedAt.isNull()))
            .get();

    for (final assoc in existing) {
      if (assoc.parentThreadId == parentThreadId) {
        // Same parent — just update the order
        await Store.get.save(
          Store.get.threadAssociations,
          assoc
              .copyWith(order: order, updatedAt: DateTime.now())
              .toCompanion(false),
          ThreadAssociationsBase(),
        );
        // Skip creating a new row since we updated in place
        Thread.push();
        return;
      }
      // Different parent — archive the old association
      await Store.get.save(
        Store.get.threadAssociations,
        assoc
            .copyWith(
              archivedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            )
            .toCompanion(false),
        ThreadAssociationsBase(),
      );
    }

    // Create the new association
    final association = ThreadAssociationRow(
      id: Uuid.generate(),
      parentThreadId: parentThreadId,
      childThreadId: id,
      order: order,
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      Store.get.threadAssociations,
      association.toCompanion(false),
      ThreadAssociationsBase(),
    );

    Thread.push();
  }

  /// Remove this thread's association with its parent event.
  /// Pure detach op: only archives the `thread_association` row; the
  /// per-user schedule is left alone so "removed from event" doesn't
  /// implicitly add the thread back to the agenda. Callers that want
  /// the classic "thread reappears as a todo" UX (e.g. drag-drop away
  /// from an event, or the X-icon "Remove from event" affordance)
  /// should also call [withScheduleRestored(order, date).save()]
  /// explicitly.
  Future<void> disassociate({required Order order}) async {
    log.info('[disassociate] "$title" order=${order.value}');

    // Archive the active association for this child thread
    final associations =
        await (Store.get.select(Store.get.threadAssociations)
              ..where((t) => t.childThreadId.equals(id.toBytes()))
              ..where((t) => t.archivedAt.isNull()))
            .get();

    for (final assoc in associations) {
      await Store.get.save(
        Store.get.threadAssociations,
        assoc
            .copyWith(
              archivedAt: Value(DateTime.now()),
              updatedAt: DateTime.now(),
            )
            .toCompanion(false),
        ThreadAssociationsBase(),
      );
    }

    Thread.push();
  }

  /// Reorder within an association group (shared order).
  Future<void> reorderAssociation(Order order) async {
    log.info('[reorderAssociation] "$title" order=${order.value}');

    final associations =
        await (Store.get.select(Store.get.threadAssociations)
              ..where((t) => t.childThreadId.equals(id.toBytes()))
              ..where((t) => t.archivedAt.isNull()))
            .get();

    if (associations.isNotEmpty) {
      final assoc = associations.first;
      await Store.get.save(
        Store.get.threadAssociations,
        assoc
            .copyWith(order: order, updatedAt: DateTime.now())
            .toCompanion(false),
        ThreadAssociationsBase(),
      );
      Thread.push();
    } else {
      log.warning('[reorderAssociation] "$title" has no active association');
    }
  }

  /// Watch all active associations, keyed by parent thread ID.
  static Stream<Map<Uuid, List<ThreadAssociationRow>>>
  watchAssociationsByParent() {
    return (Store.get.select(Store.get.threadAssociations)
          ..where((t) => t.archivedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.order)]))
        .watch()
        .map((rows) {
          final map = <Uuid, List<ThreadAssociationRow>>{};
          for (final row in rows) {
            map.putIfAbsent(row.parentThreadId, () => []).add(row);
          }
          return map;
        });
  }

  /// Optimistically set the thread-level assignee and push to the server.
  /// Use ONLY for Plot-only threads (no assignment-capable link); connector
  /// threads write the primary link's assignee instead (see pickThreadAssignee).
  static Future<void> updateAssignee(
    Thread thread,
    ActorId? newAssigneeId,
  ) async {
    final updated = thread._thread.copyWith(
      assigneeId: Value(newAssigneeId),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      Store.get.threads,
      updated.toCompanion(false),
      ThreadsBase(),
    );
  }

  Thread copyWith({
    // These fields always update the root activity
    Priority? priority,
    Order? order,
    bool? draft,
    Value<List<Uuid>?> contacts = const Value.absent(),
    Value<List<Uuid>?> droppedContacts = const Value.absent(),
    Value<Map<String, dynamic>?> contactMeta = const Value.absent(),
    Value<List<Uuid>?> groups = const Value.absent(),
    Value<List<String>?> inviteEmails = const Value.absent(),
    Value<BigInt?> teamId = const Value.absent(),
    bool? unread,
    Value<String?> preview = const Value.absent(),
    Value<String?> icon = const Value.absent(),
    Value<ThreadId?> mergedIntoThreadId = const Value.absent(),
    Value<List<Note>?> notes = const Value.absent(),

    // These fields update the exception if this is a recurrence, or the root activity otherwise
    Value<DateTimeRange?> at = const Value.absent(),
    Value<DateRange?> on = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Value<Duration?> duration = const Value.absent(),
    Value<DateTime?> archivedAt = const Value.absent(),
    // "Skip active for threads like this" mute anchor. Equal to this
    // thread's own id when the user invoked the command on this thread
    // (the seed); equal to some other id when the rule swept this thread;
    // null when cleared.
    Value<ThreadId?> muteByThreadId = const Value.absent(),

    // These fields update the root activity
    Value<DateTimeRange?> recurrenceAt = const Value.absent(),
    Value<DateRange?> recurrenceOn = const Value.absent(),
    Value<DateTime?> recurrenceDeletedAt = const Value.absent(),
    Value<RecurrenceRule?> recurrenceRule = const Value.absent(),
    Value<List<DateTime>?> recurrenceExdates = const Value.absent(),
    Value<String?> recurrenceTitle = const Value.absent(),
    Value<Duration?> recurrenceDuration = const Value.absent(),

    // Personal to-do state
    bool? todo,
    bool bump = false,
    Value<DateTime?> bumpedAt = const Value.absent(),
    Value<DateTime?> readAt = const Value.absent(),
  }) {
    final now = DateTime.now();

    // on and at are mutually exclusive
    if (at.notNull) {
      on = Value(null);
    } else if (on.notNull && this.at != null) {
      at = Value(null);
    }

    // Update root activity if any thread-specific fields are changing
    var activity = _thread;
    var activityDirty = false;
    // Whether changes require a remote push (vs local-only read-state update)
    var activityRemoteDirty = false;
    if (priority != null ||
        draft != null ||
        contacts.present ||
        droppedContacts.present ||
        contactMeta.present ||
        groups.present ||
        inviteEmails.present ||
        teamId.present ||
        unread != null ||
        preview.present ||
        icon.present ||
        mergedIntoThreadId.present ||
        archivedAt.present ||
        muteByThreadId.present ||
        bumpedAt.present ||
        readAt.present ||
        title.present) {
      activityDirty = true;
      // Read-state fields (unread, readAt, bumpedAt) sync via
      // /sync/thread-unread, not the regular thread push. Only mark remote
      // dirty when non-read-state fields change.
      activityRemoteDirty =
          priority != null ||
          draft != null ||
          contacts.present ||
          droppedContacts.present ||
          contactMeta.present ||
          groups.present ||
          inviteEmails.present ||
          teamId.present ||
          preview.present ||
          icon.present ||
          mergedIntoThreadId.present ||
          archivedAt.present ||
          muteByThreadId.present ||
          title.present;
      activity = _thread.copyWith(
        priorityId: priority?.id,
        draft: draft,
        contacts: contacts,
        droppedContacts: droppedContacts,
        contactMeta: contactMeta,
        groups: groups,
        inviteEmails: inviteEmails.present
            ? Value(
                inviteEmails.value != null && inviteEmails.value!.isNotEmpty
                    ? jsonEncode(inviteEmails.value)
                    : null,
              )
            : const Value.absent(),
        teamId: teamId,
        preview: preview,
        icon: icon,
        mergedIntoThreadId: mergedIntoThreadId,
        createdAt: draft == false && _thread.draft ? now : null,
        updatedAt: now,
        archivedAt: archivedAt,
        muteByThreadId: muteByThreadId,
        bumpedAt: bumpedAt,
        readAt: readAt,
        title: !recurring ? title : const Value.absent(),
        unread: unread,
      );
    }

    // Update schedule if scheduling fields are changing
    var schedule = _schedule;
    // Per-user thread-state field overrides applied to the thread row.
    // Non-nullable columns (active) use plain bool? where null = no change.
    // Nullable columns use Value<> with `absent` for no change.
    bool? tsActive;
    Value<bool?> tsUrgent = const Value.absent();
    Value<Order?> tsStateOrder = const Value.absent();
    Value<Date?> tsStateOn = const Value.absent();
    Value<DateTime?> tsStateAt = const Value.absent();
    Value<DateTime?> tsReadAt = readAt;
    bool stateDirty = false;

    if (at.present ||
        on.present ||
        duration.present ||
        recurrenceRule.present ||
        recurrenceExdates.present ||
        recurrenceAt.present ||
        recurrenceOn.present ||
        recurrenceDuration.present ||
        order != null) {
      if (schedule != null && schedule.linkId == null) {
        // Update existing schedule (skip link schedules — they're owned by sources)
        Value<DateTime?> schedStartAt = const Value.absent();
        Value<DateTime?> schedEndAt = const Value.absent();
        Value<Date?> schedStartOn = const Value.absent();
        Value<Date?> schedEndOn = const Value.absent();
        Value<Duration?> schedDuration = const Value.absent();

        if (recurring) {
          // Recurrence fields update the base schedule
          if (recurrenceAt.present) {
            schedStartAt = Value(recurrenceAt.value?.start);
            schedEndAt = Value(recurrenceAt.value?.end);
          }
          if (recurrenceOn.present) {
            schedStartOn = Value(recurrenceOn.value?.start);
            schedEndOn = Value(recurrenceOn.value?.end);
          }
          if (recurrenceDuration.present) schedDuration = recurrenceDuration;
          // Occurrence-level overrides
          if (at.present) {
            schedStartAt = Value(at.value?.start);
            schedEndAt = Value(at.value?.end);
          }
          if (on.present) {
            schedStartOn = Value(on.value?.start);
            schedEndOn = Value(on.value?.end);
          }
        } else {
          if (at.present) {
            schedStartAt = Value(at.value?.start);
            schedEndAt = Value(at.value?.end);
          }
          if (on.present) {
            schedStartOn = Value(on.value?.start);
            schedEndOn = Value(on.value?.end);
          }
          if (duration.present) schedDuration = duration;
        }

        schedule = schedule.copyWith(
          startAt: schedStartAt,
          endAt: schedEndAt,
          startOn: schedStartOn,
          endOn: schedEndOn,
          duration: schedDuration,
          recurrenceRule: recurrenceRule,
          recurrenceExdates: recurrenceExdates,
          updatedAt: now,
        );

        // Safety: schedule must have time data (at or on) per DB constraint.
        // If all time data was cleared, check intent:
        if (schedule.startAt == null &&
            schedule.startOn == null &&
            schedule.recurrenceRule == null &&
            schedule.occurrence == null) {
          if (at.present &&
              at.value == null &&
              on.present &&
              on.value == null) {
            // Both explicitly cleared — intentional unschedule, remove schedule
            schedule = null;
          } else {
            // Accidental clear — revert to original time data
            schedule = schedule.copyWith(
              startAt: Value(_schedule?.startAt),
              endAt: Value(_schedule?.endAt),
              startOn: Value(_schedule?.startOn),
              endOn: Value(_schedule?.endOn),
            );
          }
        }
      } else if (at.present || on.present) {
        // Per-user "do at this date / time" intent moves onto thread_state.
        // Per-user state has no end_on / end_at / duration / recurrence —
        // only the start date or start datetime is captured.
        if (at.present) tsStateAt = Value(at.value?.start);
        if (on.present) tsStateOn = Value(on.value?.start);
        if (order != null) tsStateOrder = Value(order);
        if (!_thread.active) {
          tsActive = true;
          // Promoting an inactive thread to active — populate state_order
          // when the caller didn't pass one and no prior order exists, so
          // Doing/Scheduled drag-reorders against this row sort
          // deterministically. See [Thread.order] doc for the failure mode
          // a NULL state_order causes.
          if (order == null && _thread.stateOrder == null) {
            tsStateOrder = Value(Order.first());
          }
        }
        stateDirty = true;
      } else if (order != null) {
        // Pure reorder on existing per-user state.
        tsStateOrder = Value(order);
        stateDirty = true;
      }
    }

    // Clear per-user date intent when shared schedule is intentionally removed.
    if (schedule == null && _schedule != null && (_thread.active)) {
      tsStateOn = const Value(null);
      tsStateAt = const Value(null);
      stateDirty = true;
    }

    // Handle personal to-do state.
    if (todo == true) {
      tsActive = true;
      tsStateOn = Value(Thread.todoNowDate);
      tsStateAt = const Value(null);
      tsStateOrder = Value(Order.first());
      stateDirty = true;
    }

    if (todo == false) {
      // Mark done: clear active + per-user date intent and stamp read_at
      // so the thread leaves Doing. Task / toRead flags are preserved —
      // those are independent user-set lists.
      tsActive = false;
      tsReadAt = Value(DateTime.now());
      tsStateOn = const Value(null);
      tsStateAt = const Value(null);
      stateDirty = true;
    }

    // Bump rules — both place the thread at the top of Activity as it
    // transitions in, then it drifts down naturally as newer activity
    // lands above it:
    //   1. Read transition (unread → read) while the thread will not be
    //      active. Fires for every read path because the unread-clear is
    //      what defines the transition, not the call site.
    //   2. Done transition (active → inactive via `bump: true,
    //      todo: false`).
    // Synced via /sync/thread-unread (read-state fields), so this path
    // does not need activityRemoteDirty.
    final willBeActive = todo == false ? false : _thread.active;
    final isReadTransition = unread == false && _thread.unread && !willBeActive;
    final isDoneTransition = bump && todo == false;
    if (isReadTransition || isDoneTransition) {
      activityDirty = true;
      activity = activity.copyWith(
        bumpedAt: Value(DateTime.now()),
        unread: false,
        readAt: Value(contentTimestamp),
      );
    }

    // Fold any thread-state field overrides into the activity row. Mark
    // the activity dirty so save() persists the change; the state push
    // path (POST /sync/thread-state) is selected via stateDirty rather
    // than activityRemoteDirty.
    if (stateDirty) {
      activity = activity.copyWith(
        active: tsActive,
        urgent: tsUrgent,
        stateOrder: tsStateOrder,
        stateOn: tsStateOn,
        stateAt: tsStateAt,
        readAt: tsReadAt,
        updatedAt: now,
      );
      activityDirty = true;
    } else if (readAt.present) {
      // readAt was the only state field changed via copyWith params.
      // It already landed on `activity` above via the activity copyWith
      // branch; nothing else to do here.
    }

    final scheduleDirty =
        at.present ||
        on.present ||
        duration.present ||
        recurrenceRule.present ||
        recurrenceExdates.present ||
        recurrenceAt.present ||
        recurrenceOn.present ||
        recurrenceDuration.present ||
        recurrenceDeletedAt.present;

    return Thread._fromStore(
      activity: activity,
      schedule: schedule,
      tags: _tags,
      priority: priority ?? this.priority,
      notes: notes.present ? notes.value : _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      // Clear the cached query-computed `unread` whenever this copy
      // changes the stored value — either via the explicit `unread`
      // param above or via the bump branch (`bump && todo == false`,
      // which forces `unread: false`). Without the bump-branch clear,
      // a thread the query reported as unread keeps reporting unread
      // through the [unread] getter (which prefers `_unreadComputed`
      // over `_thread.unread`) even after [asInactive] flips the
      // stored value, so the activity-feed rebuild routes the dropped
      // thread back to New instead of Done.
      unreadComputed: (unread != null || (bump && todo == false))
          ? null
          : _unreadComputed,
      activityDirty: activityDirty,
      activityRemoteDirty: activityRemoteDirty,
      scheduleDirty: scheduleDirty,
      stateDirty: stateDirty,
    );
  }

  Thread toggleTag(Tag tag) {
    // Handle computed tags
    switch (tag) {
      case Tag.archived:
        return copyWith(
          archivedAt: Value(archivedAt == null ? DateTime.now() : null),
        );
      case Tag.private:
        return this;
      case Tag.todo:
        // Toggle per-user todo (star/unstar)
        if (todo) {
          // Remove from todo: clear per-user date intent. The state row
          // stays so the thread can render in All / Done; readAt remains
          // null (the user hasn't actively read it, just unstarred).
          final now = DateTime.now();
          return _withThreadState(
            _thread.copyWith(
              stateOn: const Value(null),
              stateAt: const Value(null),
              updatedAt: now,
            ),
          );
        } else {
          // Re-add to todo: delegate to copyWith so the to-do branch
          // (active / stateOn / readAt clearing) stays in one place.
          return copyWith(todo: true);
        }
      default:
        break;
    }

    final currentTags = Map<Tag, List<ActorId>>.from(tags);
    final currentUser = Base.actorId;

    // Get current users for this tag
    final List<ActorId> currentUsers = List<ActorId>.from(
      currentTags[tag] ?? <ActorId>[],
    );

    bool isAdding = false;

    // Initialize tag updates map early since we need it for RSVP exclusivity
    final currentTagUpdates = Map<String, bool>.from(_tags?.tagsUpdated ?? {});

    if (tag.type == TagType.toggle) {
      // Toggle behavior: add if not present, remove if present
      if (currentUsers.isEmpty) {
        // Add user to tag
        currentUsers.add(currentUser);
        currentTags[tag] = currentUsers;
        isAdding = true; // Adding the tag
      } else {
        // Remove tag
        currentTags.remove(tag);
        isAdding = false; // Removing the tag
      }
    } else if (tag.type == TagType.count) {
      // Count behavior: add/remove current user while preserving other users.
      // Linked-contact aliases collapse to the canonical id, so a tag set
      // for any of the user's linked contacts counts as set for them.
      final canonicalSelf = Actor.canonicalId(currentUser);
      final hasSelfEntry = currentUsers.any(
        (id) => Actor.canonicalId(id) == canonicalSelf,
      );
      if (hasSelfEntry) {
        // Remove every linked-alias entry for the user
        currentUsers.removeWhere(
          (id) => Actor.canonicalId(id) == canonicalSelf,
        );
        if (currentUsers.isEmpty) {
          currentTags.remove(tag);
        } else {
          currentTags[tag] = currentUsers;
        }
        isAdding = false; // Removing the user's count
      } else {
        // Add user to tag (increment count) under canonical id
        currentUsers.add(canonicalSelf);
        currentTags[tag] = currentUsers;
        isAdding = true; // Adding the user's count
      }
    }

    // Update the tag updates map
    currentTagUpdates[tag.id.toString()] = isAdding;
    log.info(
      "Toggling tag ${tag.name} (${tag.type}) to $isAdding ($currentTags, $currentTagUpdates)",
    );

    final newActivity = Thread._fromStore(
      activity: _thread,
      schedule: _schedule,
      tags:
          _tags?.copyWith(
            updatedAt: DateTime.now(),
            tags: Value(currentTags),
            tagsUpdated: Value(currentTagUpdates),
          ) ??
          ThreadTagsRow(
            id: id,
            occurrence:
                _schedule?.occurrence ?? '', // Empty string for base activity
            updatedAt: DateTime.now(),
            tags: currentTags,
            tagsUpdated: currentTagUpdates.isEmpty ? null : currentTagUpdates,
          ),
      priority: priority,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
    );
    return newActivity;
  }

  /// Transitions this thread into the personal agenda, replicating the
  /// server logic in `workers/api/src/app/sync/link-tags.ts`
  /// (`unarchiveDoneLinksOnThread`) and
  /// `workers/api/src/app/sync/schedules.ts` so offline users end up in the
  /// same state as online ones.
  ///
  /// - Creates/updates the user schedule (add to agenda now)
  /// - Clears thread.archivedAt
  /// - Flips done-status links on the thread to their connector's todo
  ///   status (the one marked `todo: true`, or first non-done fallback)
  /// - Recomputes thread tags with union semantics per connector
  ///
  /// Link status changes are persisted inline (marked pending for sync).
  /// The returned Thread still needs `.save()` to persist the schedule,
  /// thread row, and tags.
  Future<Thread> addToTodoWithPropagation() async {
    final now = DateTime.now();

    // 1. Query links on this thread.
    final links = await Link.getForThread(id);

    // 2. Compute the target status per link that's currently in a done state.
    final newStatusByLinkId = <LinkId, LinkStatus>{};
    for (final link in links) {
      final config = link.getTypeConfig();
      if (config == null || link.status == null) continue;
      final currentStatusDef = config.statuses
          ?.where((s) => s.status == link.status)
          .firstOrNull;
      if (currentStatusDef == null || !currentStatusDef.done) continue;
      final target =
          config.statuses?.where((s) => s.todo).firstOrNull ??
          config.statuses?.where((s) => !s.done).firstOrNull;
      if (target == null) continue;
      newStatusByLinkId[link.id] = target;
    }

    // 3. Apply link status changes (marks each row pending for sync).
    for (final link in links) {
      final target = newStatusByLinkId[link.id];
      if (target != null) {
        await Link.updateStatus(link, target.status);
      }
    }

    // 4. Recompute thread tags with union semantics per connector.
    //    Mirrors `propagateLinkStatusTagsFromDb` in workers/api/src/app/sync/
    //    link-tags.ts — a tag stays iff any sibling link from the same
    //    connector still contributes it.
    final currentTags = Map<Tag, List<ActorId>>.from(_tags?.tags ?? const {});
    final currentTagUpdates = Map<String, bool>.from(_tags?.tagsUpdated ?? {});
    var tagsChanged = false;

    final linksByConnector = <Uuid, List<Link>>{};
    for (final link in links) {
      final cb = link.createdBy;
      if (cb == null) continue;
      linksByConnector.putIfAbsent(cb, () => []).add(link);
    }

    for (final entry in linksByConnector.entries) {
      final actor = ActorId(entry.key);
      final connectorLinks = entry.value;

      // All tags that any status across this connector's linkTypes can
      // contribute (we may need to remove some of them from the thread).
      final allPossibleTags = <Tag>{};
      // Tags this connector contributes after the status flip.
      final contributedTags = <Tag>{};

      for (final link in connectorLinks) {
        final config = link.getTypeConfig();
        if (config == null) continue;

        for (final s in config.statuses ?? const <LinkStatus>[]) {
          final tagId = s.tag;
          if (tagId != null) {
            final t = Tag.get(id: tagId);
            if (t != null) allPossibleTags.add(t);
          }
        }

        final effectiveStatus =
            newStatusByLinkId[link.id]?.status ?? link.status;
        if (effectiveStatus == null) continue;
        final statusDef = config.statuses
            ?.where((s) => s.status == effectiveStatus)
            .firstOrNull;
        final tagId = statusDef?.tag;
        if (tagId != null) {
          final t = Tag.get(id: tagId);
          if (t != null) contributedTags.add(t);
        }
      }

      // Remove this actor from any tag it no longer contributes.
      for (final tag in allPossibleTags) {
        if (contributedTags.contains(tag)) continue;
        final list = List<ActorId>.from(currentTags[tag] ?? const []);
        if (list.remove(actor)) {
          if (list.isEmpty) {
            currentTags.remove(tag);
          } else {
            currentTags[tag] = list;
          }
          currentTagUpdates[tag.id.toString()] = false;
          tagsChanged = true;
        }
      }

      // Add this actor to any tag it now contributes.
      for (final tag in contributedTags) {
        final list = List<ActorId>.from(currentTags[tag] ?? const []);
        if (!list.contains(actor)) {
          list.add(actor);
          currentTags[tag] = list;
          currentTagUpdates[tag.id.toString()] = true;
          tagsChanged = true;
        }
      }
    }

    // 5. Apply new per-user thread-state directly to the thread row
    //    (matches toggleTag(Tag.todo) add: startOn = todoNowDate, order
    //    reset, readAt cleared, active flag set).
    final wasArchived = _thread.archivedAt != null;
    final newActivity = _thread.copyWith(
      active: true,
      stateOrder: Value(Order.first()),
      stateOn: Value(Thread.todoNowDate),
      stateAt: const Value(null),
      readAt: const Value(null),
      archivedAt: wasArchived ? const Value(null) : const Value.absent(),
      updatedAt: now,
    );

    // 6. Build the new tags row (only if anything actually changed).
    final newTagsRow = tagsChanged
        ? (_tags?.copyWith(
                updatedAt: now,
                tags: Value(currentTags),
                tagsUpdated: Value(currentTagUpdates),
              ) ??
              ThreadTagsRow(
                id: id,
                occurrence: _schedule?.occurrence ?? '',
                updatedAt: now,
                tags: currentTags,
                tagsUpdated: currentTagUpdates.isEmpty
                    ? null
                    : currentTagUpdates,
              ))
        : _tags;

    return Thread._fromStore(
      activity: newActivity,
      schedule: _schedule,
      tags: newTagsRow,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      activityDirty: true,
      activityRemoteDirty: wasArchived,
      stateDirty: true,
    );
  }

  /// Save only the per-user state fields changed by [reorder]. Writes
  /// the thread row locally without setting `pending` (the remote push
  /// happens via /sync/thread-state, not /sync/threads) and posts the
  /// new state to the server.
  Future<void> saveOrder() async {
    if (!_thread.active) {
      log.warning(
        '[saveOrder] "$title" has no per-user state — nothing to save',
      );
      return;
    }
    log.info(
      '[saveOrder] "$title" saving state_order=${_thread.stateOrder?.value}',
    );
    await (Store.get.update(
      Store.get.threads,
    )..where((a) => a.id.equalsValue(id))).write(
      ThreadsCompanion(
        stateOrder: Value(_thread.stateOrder),
        updatedAt: Value(_thread.updatedAt),
      ),
    );
    _pushThreadState();
  }

  /// Insert this thread's row into the local DB if it doesn't already
  /// exist. Used for new in-memory drafts on first content edit, where
  /// only the note has changed and a regular [save] would skip the row
  /// (because [_activityDirty] is false). Without this, the thread row
  /// never lands locally and chain/priority draft lookups can't find it.
  Future<void> ensurePersisted() async {
    if (!Store.isAvailable) return;
    await Store.get
        .into(Store.get.threads)
        .insert(_thread.toCompanion(false), mode: InsertMode.insertOrIgnore);
  }

  /// POST the per-user state fields to /sync/thread-state. Fire-and-forget;
  /// we don't await the response. Errors are logged.
  void _pushThreadState() {
    final body = <String, dynamic>{
      'thread_id': id.toString(),
      'active': _thread.active,
      if (_thread.urgent != null) 'urgent': _thread.urgent,
      'importance': _thread.importance,
      if (_thread.stateOrder != null) 'order': _thread.stateOrder!.value,
      if (_thread.stateOn != null) 'on': '[${_thread.stateOn},)',
      if (_thread.stateAt != null)
        'at': '["${_thread.stateAt!.toIso8601String()}",)',
      if (_thread.readAt != null) 'read_at': _thread.readAt!.toIso8601String(),
      if (_thread.bumpedAt != null)
        'bumped_at': _thread.bumpedAt!.toIso8601String(),
    };
    () async {
      try {
        await api.post<Map<String, dynamic>>('/sync/thread-state', body: body);
      } catch (e, t) {
        log.warning('Failed to push thread state for $id: $e\n$t');
      }
    }();
  }

  Future<void> save() async {
    if (!Store.isAvailable) return;
    if (_activityDirty) {
      if (_activityRemoteDirty) {
        // Full save: marks row pending for remote sync
        await Store.get.save(
          Store.get.threads,
          _thread.toCompanion(false),
          ThreadsBase(),
        );
      } else {
        // Local-only update for read-state / per-user-state fields
        // (unread, readAt, active, urgent, state_order, state_on, state_at,
        // importance, bumpedAt). These sync via
        // /sync/thread-state, not the regular thread push. Use
        // update().write() to avoid setting pending (which would trigger
        // a full thread sync that fails for viewer members).
        await (Store.get.update(
          Store.get.threads,
        )..where((a) => a.id.equalsValue(id))).write(
          ThreadsCompanion(
            unread: Value(_thread.unread),
            importance: Value(_thread.importance),
            active: Value(_thread.active),
            urgent: Value(_thread.urgent),
            stateOrder: Value(_thread.stateOrder),
            stateOn: Value(_thread.stateOn),
            stateAt: Value(_thread.stateAt),
            readAt: Value(_thread.readAt),
            bumpedAt: Value(_thread.bumpedAt),
            updatedAt: Value(_thread.updatedAt),
          ),
        );
        // ThreadsCompanion uses Value<> for all columns so the above
        // works for both nullable and non-nullable fields.
      }
    } else {
      // Thread row wasn't written — ensure it exists in the local DB so
      // the draft filter can correctly exclude child rows (schedules, tags)
      // from being pushed before the thread itself. Uses insertOrIgnore so
      // an existing row (and its pending flag) is never overwritten.
      final hasChildRows =
          _tags != null ||
          (_scheduleDirty && _schedule != null && _schedule.linkId == null);
      if (hasChildRows) {
        await Store.get
            .into(Store.get.threads)
            .insert(
              _thread.toCompanion(false),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }
    if (_scheduleDirty && _schedule != null) {
      if (_schedule.linkId == null) {
        await Store.get.save(
          Store.get.schedules,
          _schedule.toCompanion(false),
          SchedulesBase(),
        );
      } else {
        // Link schedules are server-owned and rejected by /sync/schedules.
        // Persist only the RSVP-derived fields locally so the optimistic
        // update survives refreshAgenda(); the server-side status is
        // reconciled via POST /sync/schedule/status from the caller.
        await (Store.get.update(
          Store.get.schedules,
        )..where((a) => a.id.equalsValue(_schedule.id))).write(
          SchedulesCompanion(
            contacts: Value(_schedule.contacts),
            currentUserStatus: Value(_schedule.currentUserStatus),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    }
    if (_tags != null) {
      await Store.get.save(
        Store.get.threadTags,
        _tags.toCompanion(false),
        ThreadTagsBase(),
      );
    }

    // Push per-user state changes via /sync/thread-state.
    if (_stateDirty) {
      _pushThreadState();
    }

    // Trigger full push including activity_read changes. Deferred to idle
    // so it doesn't compete for CPU with navigation transitions running
    // concurrently (e.g. the new-thread submit → ThreadPage flip).
    _deferIdle(Thread.push, debugLabel: 'thread push');

    // Generate AI title on first non-draft save. Fire-and-forget so callers
    // (e.g. NewThreadPage submit → navigation) don't block on a /summary
    // round-trip. The title appears on the thread page once /summary returns.
    // If offline/error, leaves title null — displayTitle derives from preview,
    // and the server will generate an AI title when the thread syncs.
    if (title == null && !draft) {
      final content = preview;
      if (content != null && content.trim().isNotEmpty) {
        final threadId = id;
        _deferIdle(() async {
          try {
            final response = await api.post<Map<String, dynamic>>(
              '/summary',
              body: {'body': content},
            );
            final generatedTitle = response['title'] as String?;
            if (generatedTitle != null && generatedTitle.isNotEmpty) {
              log.info(
                "Generated AI title for thread $threadId: $generatedTitle",
              );
              await copyWith(title: Value(generatedTitle)).save();
            }
          } catch (e, t) {
            log.warning(
              "AI title generation failed for thread $threadId "
              "(will retry on sync): $e\n$t",
            );
          }
        }, debugLabel: 'thread AI title');
      }
    }
  }

  Future<void> delete() => copyWith(archivedAt: Value(DateTime.now())).save();

  bool hasTag(Tag tag, {ActorId? actorId}) {
    switch (tag) {
      case Tag.todo:
        return todo;
      case Tag.archived:
        return archivedAt != null;
      case Tag.private:
        return false;
      default:
        final currentTags = tags;
        final users = currentTags[tag];
        if (users == null || users.isEmpty) return false;
        if (actorId == null) return true;
        // Linked-contact aliases collapse to the canonical id.
        final canonical = Actor.canonicalId(actorId);
        return users.any((id) => Actor.canonicalId(id) == canonical);
    }
  }

  /// Get actor names for a tag, formatted for display in tooltips
  /// Returns a formatted string like "You, Alice, Bob" or "You, Alice, Bob + 2 more"
  Future<String> getTagActorNames(Tag tag) async {
    // Default behavior for all tags
    final actorIds = tags[tag];
    if (actorIds == null || actorIds.isEmpty) {
      return '';
    }

    // Calculate hidden voters (total count minus visible actors)
    final hiddenCount = actorIds is TagActors
        ? actorIds.count - actorIds.length
        : 0;

    return Thread._formatActorNames(actorIds, hiddenCount: hiddenCount);
  }

  /// Helper to format a list of actorIds into a display string
  /// - Replaces current user with "You"
  /// - Shows first 3 names + count if more exist
  /// - [hiddenCount] adds extra hidden voters to the "more" count
  static Future<String> _formatActorNames(
    List<ActorId> actorIds, {
    int hiddenCount = 0,
  }) async {
    if (actorIds.isEmpty && hiddenCount == 0) return '';

    // Fetch actor names from the database
    final actorRows =
        await (Store.get.select(Store.get.actors)..where(
              (a) => a.id.isIn(actorIds.map((id) => id.toBytes()).toList()),
            ))
            .get();

    // Convert to Actor objects and create a map of actorId to nameOrEmail
    final actors = actorRows.map((row) => Actor.fromStore(row)).toList();
    final actorMap = {for (var actor in actors) actor.id: actor.nameOrEmail};

    // Build the display names list
    final displayNames = <String>[];
    final currentContactId = Base.actorId;

    for (final actorId in actorIds) {
      if (actorId == currentContactId) {
        displayNames.insert(0, 'You'); // Put "You" first
      } else {
        final name = actorMap[actorId] ?? 'Unknown';
        displayNames.add(name);
      }
    }

    // Format the output
    final totalExtra =
        (displayNames.length > 3 ? displayNames.length - 3 : 0) + hiddenCount;
    if (totalExtra == 0) {
      return displayNames.join(', ');
    } else {
      final first3 = displayNames.take(3).join(', ');
      return '$first3 + $totalExtra more';
    }
  }

  /// Picks the representative occurrence schedule row from a set of
  /// candidates. Returns the earliest whose end is `>= now` (next
  /// upcoming); if none, returns the latest whose end is `< now` (most
  /// recent past). Returns null when no candidate qualifies.
  ///
  /// `generatedInstances` are rrule-generated rows (their currentUserStatus
  /// is copied from the series base). `overrideRows` are persisted
  /// schedule rows with `occurrence IS NOT NULL`. Overrides replace
  /// generated instances at matching occurrence keys. Cancelled
  /// occurrences are excluded earlier via the parent series'
  /// `recurrenceExdates` (see `generateOccurrences`); they never appear
  /// here as override rows.
  ///
  /// The returned `isOverride` distinguishes a persisted-override row
  /// from a generated instance — used by the caller to decide the
  /// default value of `rsvpInheritedFromSeries`.
  @visibleForTesting
  static ({ScheduleRow row, bool isOverride})? selectRepresentativeOccurrence({
    required List<ScheduleRow> generatedInstances,
    required List<ScheduleRow> overrideRows,
    required DateTime now,
  }) {
    final merged = <String, ({ScheduleRow row, bool isOverride})>{};

    for (final row in generatedInstances) {
      final key = row.occurrence;
      if (key == null) continue;
      merged[key] = (row: row, isOverride: false);
    }

    for (final override in overrideRows) {
      final key = override.occurrence;
      if (key == null) continue;
      merged[key] = (row: override, isOverride: true);
    }

    if (merged.isEmpty) return null;

    DateTime? rowEnd(ScheduleRow r) =>
        r.endAt ??
        r.endOn?.toDateTime() ??
        r.startAt ??
        r.startOn?.toDateTime();

    ({ScheduleRow row, bool isOverride})? earliestUpcoming;
    ({ScheduleRow row, bool isOverride})? latestPast;

    for (final candidate in merged.values) {
      final end = rowEnd(candidate.row);
      if (end == null) continue;
      if (!end.isBefore(now)) {
        if (earliestUpcoming == null ||
            end.isBefore(rowEnd(earliestUpcoming.row)!)) {
          earliestUpcoming = candidate;
        }
      } else {
        if (latestPast == null || end.isAfter(rowEnd(latestPast.row)!)) {
          latestPast = candidate;
        }
      }
    }

    return earliestUpcoming ?? latestPast;
  }

  /// Returns a copy of this thread combined with the representative
  /// schedule resolved by [loadRepresentativeForFeed]. Activity-feed rows
  /// for calendar events cache the resolved representative (to avoid
  /// reissuing the schedule lookup on every rebuild), but the cached
  /// result freezes the rest of the thread's state (unread, title, tags,
  /// …) at the time of the lookup. Composing the live `this` with the
  /// representative's picked occurrence + flags keeps the display fresh
  /// while preserving the cached schedule selection.
  Thread withRepresentativeFrom(Thread representative) {
    return Thread._fromStore(
      activity: _thread,
      priority: priority,
      schedule: representative._schedule,
      tags: _tags,
      notes: _notes,
      active: _active,
      unreadComputed: _unreadComputed,
      isLinkScheduleInstance: true,
      rsvpInheritedFromSeries: representative.rsvpInheritedFromSeries,
      linkSourceCreatedAt: _linkSourceCreatedAt,
    );
  }

  /// Resolves a Thread to its representative occurrence for the activity
  /// feed. For non-recurring calendar events returns a Thread with the
  /// same single schedule wrapped as a link schedule instance. For
  /// recurring events, generates instances within
  /// `[now - lookBack, now + lookAhead]`, merges persisted overrides,
  /// and selects the earliest upcoming (else latest past) as the
  /// representative. Returns null if the base thread isn't a feed-eligible
  /// calendar event, or if no qualifying occurrence lies within the
  /// lookup window.
  static Future<Thread?> loadRepresentativeForFeed(
    Thread base, {
    required DateTime now,
    Duration lookAhead = const Duration(days: 90),
    Duration lookBack = const Duration(days: 30),
  }) async {
    // Gate 1: must be a calendar event (link schedule).
    if (!base.hasLinkSchedule) return null;

    // Gate 2: todo base — a todo thread that isn't already an instance
    // is not a calendar event for RSVP purposes.
    if (base.todo && !base.isLinkScheduleInstance) return null;

    final schedule = base._schedule;
    if (schedule == null) return null;

    // Non-recurring: the one schedule IS the occurrence. Wrap as an
    // instance so the widget gating treats it as a calendar event.
    if (!base.recurring) {
      return Thread._fromStore(
        activity: base._thread,
        priority: base.priority,
        schedule: schedule,
        tags: base._tags,
        active: base._active,
        unreadComputed: base._unreadComputed,
        isLinkScheduleInstance: true,
        rsvpInheritedFromSeries: false,
        linkSourceCreatedAt: base._linkSourceCreatedAt,
      );
    }

    // Recurring: generate instances in a bounded window.
    // CustomBoundedDateRange takes Date objects — use DateTime.toDate() extension.
    final window = CustomBoundedDateRange(
      now.subtract(lookBack).toDate(),
      now.add(lookAhead).toDate(),
    );

    List<Thread> generated;
    try {
      generated = base.generateOccurrences(window);
    } catch (e, t) {
      log.warning(
        "Error generating occurrences for feed representative of ${base.id}: $e\n$t",
      );
      Tracker.captureException(e, t);
      generated = const [];
    }
    final generatedRows = generated
        .map((t) => t._schedule!)
        .toList(growable: false);

    // Load all schedule rows for the same link (overrides + base), filter
    // to override rows (occurrence != null), partition by archived.
    final linkId = schedule.linkId;
    List<ScheduleRow> allRows;
    if (linkId != null) {
      allRows = await (Store.get.select(
        Store.get.schedules,
      )..where((s) => s.linkId.equals(linkId.toBytes()))).get();
    } else {
      allRows = await (Store.get.select(
        Store.get.schedules,
      )..where((s) => s.threadId.equals(base.id.toBytes()))).get();
    }

    final overrideRows = <ScheduleRow>[];
    for (final row in allRows) {
      if (row.occurrence == null) continue; // skip base series row
      overrideRows.add(row);
    }

    final picked = selectRepresentativeOccurrence(
      generatedInstances: generatedRows,
      overrideRows: overrideRows,
      now: now,
    );

    if (picked == null) return null;

    // rsvpInheritedFromSeries:
    //   - Generated row: always true (its contacts are a copy of the series).
    //   - Override row: check whether any ScheduleContact on the override
    //     belongs to the current user. If none, the visible status was
    //     inherited from the series.
    final userIdStr = Base.userId.toString();
    bool overrideHasUserContact(ScheduleRow row) {
      final json = row.contacts;
      if (json == null || json.isEmpty) return false;
      try {
        final list = jsonDecode(json) as List<dynamic>;
        return list.any((e) {
          final m = e as Map<String, dynamic>;
          return m['contact_user_id'] == userIdStr && m['status'] != null;
        });
      } catch (_) {
        return false;
      }
    }

    final inherited = !picked.isOverride || !overrideHasUserContact(picked.row);

    return Thread._fromStore(
      activity: base._thread,
      priority: base.priority,
      schedule: picked.row,
      tags: base._tags,
      active: base._active,
      unreadComputed: base._unreadComputed,
      isLinkScheduleInstance: true,
      rsvpInheritedFromSeries: inherited,
      linkSourceCreatedAt: base._linkSourceCreatedAt,
    );
  }

  List<Thread> generateOccurrences(BoundedDateRange range) {
    // For non-recurring activities, return just this activity
    if (!recurring) {
      return [this];
    }

    // For recurring activities, generate occurrences using the RecurrenceRule
    List<Thread> occurrences = [];

    // Convert BoundedDateRange to DateTime range for rrule package
    final dateTimeRange = BoundedDateTimeRange(
      range.start.toDateTime(),
      range.end.toDateTime(),
    );

    // Get the event start time
    final start = (at?.start ?? on?.start?.toDateTime())!;

    // If the range ends before the event starts, there are no occurrences
    if (dateTimeRange.end.isBefore(start)) {
      return [];
    }

    // Generate instances within the range using the rrule package
    final instances = recurrenceRule!.getInstances(
      start: start.copyWith(isUtc: true),
      after: (start.isAfter(dateTimeRange.start) ? start : dateTimeRange.start)
          .copyWith(isUtc: true),
      includeAfter: true,
      before: dateTimeRange.end.copyWith(isUtc: true),
    );

    // Convert instances to a set for efficient exclusion checking
    final instanceSet = Set<DateTime>.from(
      instances.map((dt) => dt.copyWith(isUtc: false)),
    );

    // Apply recurrenceExdates (dates to exclude).
    // Exdates are UTC; instances are local. Use toLocal() to convert the
    // actual point-in-time, not just strip the UTC flag.
    if (recurrenceExdates?.isNotEmpty == true) {
      instanceSet.removeAll(
        recurrenceExdates!
            .where((dt) => range.includes(dt.toDate()))
            .map((dt) => dt.toLocal()),
      );
    }

    // Convert back to sorted list
    final finalInstances = instanceSet.toList()..sort();

    for (final instance in finalInstances) {
      // Create a new occurrence for each instance
      final occurrenceAt = at != null
          ? DateTimeRange(instance, instance.add(duration!))
          : null;
      final occurrenceOn = on != null
          ? CustomDateRange(
              instance.toDate(),
              instance.toDate().addDays(duration!.inDays),
            )
          : null;

      // Format occurrence string based on whether this is date or datetime based
      final occurrence = Thread._fromStore(
        activity: _thread,
        schedule: ScheduleRow(
          id: Uuid.generate(),
          updatedAt: DateTime.now(),
          threadId: id,
          occurrence: Schedules.formatOccurrence(
            instance,
            dateOnly: at == null,
          ),
          startAt: occurrenceAt?.start,
          endAt: occurrenceAt?.end,
          startOn: occurrenceOn?.start,
          endOn: occurrenceOn?.end,
          recurrenceRule: _schedule?.recurrenceRule,
          recurrenceExdates: _schedule?.recurrenceExdates,
          contacts: _schedule?.contacts,
          currentUserStatus: _schedule?.currentUserStatus,
        ),
        priority: priority,
        tags: _tags,
        isLinkScheduleInstance: isLinkScheduleInstance,
        rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      );

      occurrences.add(occurrence);
    }

    return occurrences;
  }

  Date? nextOccurrence(BoundedDateRange range, {bool reverse = false}) {
    if (recurrenceRule == null) {
      return null;
    }

    // Convert BoundedDateRange to DateTime range for rrule package
    final dateTimeRange = BoundedDateTimeRange(
      range.start.toDateTime(),
      range.end.toDateTime(),
    );

    // Get the event start time
    final start = (at?.start ?? on?.start?.toDateTime())!;

    // If the range ends before the event starts, there are no occurrences
    if (dateTimeRange.end.isBefore(start)) {
      return null;
    }

    // Generate instances within the range using the rrule package
    final instances = recurrenceRule!.getInstances(
      start: start.copyWith(isUtc: true),
      after: (start.isAfter(dateTimeRange.start) ? start : dateTimeRange.start)
          .copyWith(isUtc: true),
      includeAfter: true,
      before: dateTimeRange.end.copyWith(isUtc: true),
    );

    // Convert instances to check for overlaps
    final instanceSet = Set<DateTime>.from(
      instances.map((dt) => dt.copyWith(isUtc: false)),
    );

    // Apply recurrenceExdates (dates to exclude).
    // Exdates are UTC; instances are local. Use toLocal() to convert the
    // actual point-in-time, not just strip the UTC flag.
    if (recurrenceExdates?.isNotEmpty == true) {
      instanceSet.removeAll(
        recurrenceExdates!
            .where((dt) => range.includes(dt.toDate()))
            .map((dt) => dt.toLocal()),
      );
    }

    if (instanceSet.isEmpty) {
      return null;
    }

    // Sort instances and return the first or last based on reverse parameter
    final sortedInstances = instanceSet.toList()..sort();
    final targetInstance = reverse
        ? sortedInstances.last
        : sortedInstances.first;

    // Convert to Date and verify it's within the intended range
    // This ensures occurrences at range boundaries are properly excluded
    final targetDate = targetInstance.toDate();
    if (!range.includes(targetDate)) {
      return null;
    }

    return targetDate;
  }

  /// Activity are sorted by schedule time, then creation time.
  /// Ties are broken using the order property.
  @override
  int compareTo(Thread other) {
    final thisTime = _getSortTime();
    final otherTime = other._getSortTime();

    final timeComparison = thisTime.compareTo(otherTime);
    if (timeComparison != 0) {
      return timeComparison;
    }

    return order.compareTo(other.order);
  }

  DateTime _getSortTime() {
    return at?.start ??
        on?.start?.toDateTime() ??
        _thread.lastNoteSourceCreatedAt ??
        createdAt;
  }

  @override
  List<Object?> get props => [
    _thread,
    _schedule,
    _tags,
    _notes,
    priority,
    isLinkScheduleInstance,
    _linkSourceCreatedAt,
  ];

  @override
  String toString() {
    final buffer = StringBuffer('Thread(');

    // ID
    buffer.write('id: ${id.toString().substring(0, 8)}..., ');

    // Title (truncated)
    final titleStr = title;
    if (titleStr != null) {
      final truncatedTitle = titleStr.length > 50
          ? '${titleStr.substring(0, 47)}...'
          : titleStr;
      buffer.write('title: "$truncatedTitle", ');
    }

    // Preview (truncated)
    final previewStr = preview;
    if (previewStr != null && previewStr.isNotEmpty) {
      final truncatedPreview = previewStr.length > 50
          ? '${previewStr.substring(0, 47)}...'
          : previewStr;
      buffer.write('preview: "$truncatedPreview", ');
    }

    // Priority
    buffer.write('priority: ${priority.title}, ');

    // Scheduling info
    if (at != null) {
      buffer.write('at: ${at!.start}, ');
    } else if (on != null) {
      buffer.write('on: ${on!.start}, ');
    }

    if (archivedAt != null) {
      buffer.write('archived: $archivedAt, ');
    }

    if (draft) {
      buffer.write('draft: true, ');
    }

    // Remove trailing comma and space
    final result = buffer.toString();
    if (result.endsWith(', ')) {
      return '${result.substring(0, result.length - 2)})';
    }
    return '$result)';
  }

  /// Query the server for threads matching [query] and hydrate them into the
  /// local store so they render in search results and are openable offline.
  /// Returns the hydrated threads.
  static Future<List<Thread>> searchRemote(
    String query, {
    required bool archived,
    PriorityId? priorityId,
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) return [];

    final params = <String, String>{
      'q': query,
      'archived': archived.toString(),
      'limit': limit.toString(),
      if (priorityId != null) 'priority_id': priorityId.toString(),
    };
    final queryString = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    final raw = await api.get<List<dynamic>>(
      '/sync/threads/search?$queryString',
    );
    final rows = raw.cast<Map<String, dynamic>>();
    if (rows.isEmpty) return [];

    // Hydrate into the local threads table using the same pipeline as
    // /sync/threads pulls.
    final base = ThreadsBase();
    final storeRows = <Insertable<ThreadRow>>[];
    for (final row in rows) {
      try {
        storeRows.add(base.fromBase(row));
      } catch (e, st) {
        log.warning('Error parsing remote search row', e, st);
      }
    }
    final processed = await base.processPulledRows(Store.get, storeRows);
    await Store.get.batch((batch) {
      batch.insertAll(
        Store.get.threads,
        processed,
        mode: InsertMode.insertOrReplace,
      );
    });

    // Load the hydrated threads back out so callers get fully-joined Thread
    // objects (schedules, links, priority, etc).
    final ids = <ThreadId>[];
    for (final r in rows) {
      final raw = r['id'];
      if (raw is String) {
        try {
          ids.add(Uuid.fromString(raw));
        } catch (_) {
          // Skip malformed ids.
        }
      }
    }
    if (ids.isEmpty) return [];

    final threads = <Thread>[];
    for (final id in ids) {
      try {
        final list = await _get(
          id: id,
          archived: null,
          draft: null,
          order: ThreadOrder.sorted,
        );
        if (list.isNotEmpty) threads.add(list.first);
      } catch (e) {
        // Skip threads that fail to load locally.
      }
    }
    return threads;
  }

  /// Ask the server how many threads match [query] under the given
  /// [archived] scope. Used to decide whether to surface a
  /// "view archived matches" affordance.
  static Future<int> searchRemoteCount(
    String query, {
    required bool archived,
    PriorityId? priorityId,
  }) async {
    if (query.trim().isEmpty) return 0;

    final params = <String, String>{
      'q': query,
      'archived': archived.toString(),
      'count_only': 'true',
      if (priorityId != null) 'priority_id': priorityId.toString(),
    };
    final queryString = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    final result = await api.get<Map<String, dynamic>>(
      '/sync/threads/search?$queryString',
    );
    final count = result['count'];
    if (count is int) return count;
    if (count is num) return count.toInt();
    return 0;
  }
}

/// Pending sync flags for different entity types.
/// Bit 1 is reserved for sync-in-progress flag.
/// Entity-specific flags start from bit 2 (value 2).
enum ThreadPendingSync {
  /// Full activity data changed
  full(2),

  /// Only tags changed
  tags(4),

  /// Only schedules changed
  schedules(8);

  const ThreadPendingSync(this.value);
  final int value;
}
