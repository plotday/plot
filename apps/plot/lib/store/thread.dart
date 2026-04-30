part of 'store.dart';

typedef ThreadId = Uuid;
typedef ThreadWatchResult = ({List<Thread> threads, int rawRowCount});

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

  /// Group IDs attached to this thread for dynamic visibility.
  TextColumn get groups => text().nullable().map(const UuidListConverter())();

  /// Routing key used by priority rules. Defaults (server-side) to the first
  /// group id stringified, or to `channel:<id>` for connection-sourced threads.
  TextColumn get topic => text().nullable()();

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
  TextColumn get urgency => text().nullable()();
  DateTimeColumn get readAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get bumpedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get icon => text().nullable()();

  /// Whether the thread has a content embedding on the server.
  /// Used to decide whether "move similar" rule options are available.
  BoolColumn get hasEmbedding =>
      boolean().withDefault(const Constant(false))();
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
  static String canonicalOccurrence(
    String stored, {
    required bool dateOnly,
  }) {
    final parsed = DateTime.tryParse(stored);
    if (parsed == null) return stored;
    // Date-only events are TZ-agnostic (Google sends `originalStartTime.date`
    // as `YYYY-MM-DD`, which the API serialises as UTC midnight) — keep the
    // calendar date as-is rather than shifting it across the user's TZ.
    if (dateOnly) return formatOccurrence(parsed, dateOnly: true);
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    return formatOccurrence(local, dateOnly: false);
  }

  BlobColumn get userId => blob().nullable().map(const UuidConverter())();
  RealColumn get order => real().nullable().map(const OrderConverter())();
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
  BoolColumn get outstandingTasks =>
      boolean().withDefault(const Constant(false))();
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
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final activityRow = row as ThreadRow;
      final local = await (store.select(
        store.threads,
      )..where((t) => t.id.equals(activityRow.id.toBytes())))
          .getSingleOrNull();
      var merged = activityRow;

      // Conflict resolution: local has a pending read (readAt != null)
      if (local != null && local.readAt != null) {
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
            urgency: const Value(null),
            readAt: Value(local.readAt),
          );
        }
      }

      result.add(merged);
    }
    return result;
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Convert author_id from ActorId bytes to UUID string for the API
    // The client sets this correctly to Base.actorId (contact ID)
    // Do NOT remove - the sync API needs it to set the correct author

    // Remove unread fields - they are managed separately
    json.remove('unread');
    json.remove('importance');
    json.remove('urgency');
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

    // Add user_id for per-user schedules
    if (json['user_id'] != null) {
      json['user_id'] = json['user_id'].toString();
    }

    // Remove local-only fields
    json.remove('contacts');
    json.remove('current_user_status');

    // Per-user schedules: always include at/on explicitly (even if null)
    // to ensure the server's upsert_schedule clears these fields.
    // Without this, absent keys are treated as "keep existing" and stale
    // dates (e.g. from a previous todo toggle) persist on the server,
    // causing the thread to flip back to "To Do" on next pull.
    if (json['user_id'] != null &&
        !json.containsKey('at') &&
        !json.containsKey('on')) {
      json['at'] = null;
      json['on'] = null;
    }

    // Safety: DB constraint requires exactly one of at/on to be set,
    // unless it's a per-user schedule (user_id IS NOT NULL) which can be undated.
    // If neither is present and it's a shared schedule, default to today.
    if (!json.containsKey('at') &&
        !json.containsKey('on') &&
        json['user_id'] == null) {
      final today = DateTime.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      json['on'] = '[$dateStr,)';
    }

    return json;
  }

  @override
  Insertable<ScheduleRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    // Map schedule_user_id → user_id (view returns user_id as authenticated user,
    // schedule_user_id as the actual schedule's user_id)
    json['user_id'] = json.remove('schedule_user_id');
    json.remove('priority_path');
    json.remove('range_at');
    json.remove('range_on');

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
    await Store.get.pull(
      Store.get.threadAssociations,
      ThreadAssociationsBase(),
    );
  }

  /// Pull one page of activity feed (backward from now).
  /// Uses SyncState entity "activity-feed:{priorityPath}" to track position.
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
      rangeStart: DateTime.now().toUtc(),
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
    final success =
        await Store.get.push(Store.get.threads, ThreadsBase()) &&
        await Store.get.push(Store.get.links, LinksBase()) &&
        await Store.get.push(Store.get.schedules, SchedulesBase()) &&
        await Store.get.push(
          Store.get.threadAssociations,
          ThreadAssociationsBase(),
        ) &&
        await Store.get.push(Store.get.threadTags, ThreadTagsBase());

    // Push pending read changes (readAt != null means user read locally)
    final readActivities = await (Store.get.select(
      Store.get.threads,
    )..where((t) => t.readAt.isNotNull()))
        .get();

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
    ThreadId? id,
    PriorityId? priorityId,
    Path? priorityPath,
    bool? archived = false,
    bool? draft = false,
    String? search,
    bool self = true,
    ThreadOrder order = ThreadOrder.sorted,
    List<Tag>? filter,
    List<String>? iconFilter,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    int? limit,
  }) async {
    return await _get(
      range: range,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      archived: archived,
      draft: draft,
      order: order,
      search: search,
      self: self,
      filter: filter,
      iconFilter: iconFilter,
      includeAllFutureEvents: includeAllFutureEvents,
      includeUnscheduled: includeUnscheduled,
      limit: limit,
    );
  }

  static Stream<ThreadWatchResult> watch({
    DateRange? range,
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
    List<String>? iconFilter,
    bool includeAllFutureEvents = false,
    bool includeUnscheduled = true,
    bool linkScheduledOnly = false,
    int? limit,
    int? offset,
  }) {
    // Resolve contact-name matches once per search before opening the
    // change-driven stream. New search text triggers a new subscription,
    // so we don't need to re-resolve when contacts are inserted/updated.
    return Stream.fromFuture(_resolveContactIdMatches(search)).asyncExpand((
      contactIdMatchesPerWord,
    ) {
      return _getQuery(
        range: range,
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
        iconFilter: iconFilter,
        includeAllFutureEvents: includeAllFutureEvents,
        includeUnscheduled: linkScheduledOnly ? false : includeUnscheduled,
        linkScheduledOnly: linkScheduledOnly,
        limit: limit,
        offset: offset,
      ).watch().asyncMap((results) async {
      if (!Store.isAvailable) return (threads: <Thread>[], rawRowCount: 0);
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
      return (threads: threads, rawRowCount: results.length);
    });
    });
  }

  /// Watch threads that are children of active thread associations.
  /// Uses the same table aliases as [_getQuery] so results can be processed
  /// by [_mapResultsToThreads].
  static Stream<List<Thread>> watchAssociatedThreads() {
    final a = Store.get.alias(Store.get.threads, 'a');
    final sched = Store.get.alias(Store.get.schedules, 'sched');
    final userSched = Store.get.alias(Store.get.schedules, 'user_sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');
    final tags = Store.get.alias(Store.get.threadTags, 'tags');
    final ta = Store.get.threadAssociations;

    final query = Store.get.select(a).join([
      // INNER JOIN thread_associations to select only associated children
      innerJoin(
        ta,
        ta.childThreadId.equalsExp(a.id) & ta.archivedAt.isNull(),
      ),
      // Same joins as _getQuery so _mapResultsToThreads works
      leftOuterJoin(
        sched,
        sched.threadId.equalsExp(a.id) & sched.userId.isNull(),
      ),
      leftOuterJoin(
        userSched,
        userSched.threadId.equalsExp(a.id) &
            userSched.userId.equalsValue(Base.userId) &
            userSched.occurrence.isNull(),
      ),
      leftOuterJoin(linkTable, linkTable.threadId.equalsExp(a.id)),
      leftOuterJoin(
        linkSched,
        linkSched.linkId.equalsExp(linkTable.id) & linkSched.userId.isNull(),
      ),
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
      // System priorities (@plot, @plot.app, @plot.twist-dev) are
      // infrastructure, not user branches — their drafts must not follow
      // the user out of that context (otherwise a stray twist-dev draft
      // gets loaded at root and NewThreadPage shows its "Select a thread"
      // twist-dev placeholder instead of the editor).
      if (d.priority.isPlot) return false;
      final dp = d.priority.path.value;
      return dp == pathStr ||
          pathStr.startsWith('$dp.') || // ancestor
          dp.startsWith('$pathStr.'); // descendant
    }).toList();
    if (chainDrafts.isEmpty) return null;
    chainDrafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chainDrafts.first;
  }

  /// Watch all tags present in threads within a priority and its descendants.
  /// Returns a stream of (Tag, count) tuples sorted by occurrence count descending.
  static Stream<List<(Tag, int)>> watchTagsForPriority(Path priorityPath) {
    final at = Store.get.threadTags;
    final a = Store.get.threads;
    final p = Store.get.priorities;

    final now = DateTime.now();
    final today = Date.today().toString();
    final priorityPathLike = '$priorityPath.%';

    // Query for stored tags from activity_tags table
    final tagsQuery = Store.get.select(at).join([
      innerJoin(a, a.id.equalsExp(at.id)),
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);

    tagsQuery.where(a.archivedAt.isNull());

    // COUNT query for Tag.todo
    final s = Store.get.schedules;
    final us = Store.get.alias(Store.get.schedules, 'us');
    final nowQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    nowQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
      leftOuterJoin(s, s.threadId.equalsExp(a.id) & s.userId.isNull()),
      leftOuterJoin(
        us,
        us.threadId.equalsExp(a.id) &
            us.userId.equalsValue(Base.userId) &
            us.occurrence.isNull(),
      ),
    ]);
    nowQuery.where(
      a.archivedAt.isNull() &
          (
          // Date-based scheduling: startOn <= today
          (s.startOn.isSmallerOrEqualValue(today) & s.startAt.isNull()) |
              // DateTime-based scheduling: startAt <= now AND endAt >= now
              (s.startAt.isSmallerOrEqualValue(now) &
                  (s.endAt.isNull() | s.endAt.isBiggerOrEqualValue(now))) |
              // Per-user todo: non-archived per-user schedule exists
              (us.id.isNotNull() & us.archivedAt.isNull())),
    );
    final nowCountStream = nowQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for Tag.archived
    final archivedQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    archivedQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
      ),
    ]);
    archivedQuery.where(a.archivedAt.isNotNull());
    final archivedCountStream = archivedQuery.watch().map(
      (rows) => rows.map((r) => r.read(a.id)).toSet().length,
    );

    // COUNT query for archived priorities
    final archivedPriorityQuery = Store.get.selectOnly(p)..addColumns([p.id]);
    archivedPriorityQuery.where(
      (p.path.equalsValue(priorityPath) |
              p.path.likeExp(Constant(priorityPathLike))) &
          p.archivedAt.isNotNull(),
    );
    final archivedPriorityCountStream = archivedPriorityQuery.watch().map(
      (rows) => rows.length,
    );

    // COUNT query for Tag.unread
    final unreadQuery = Store.get.selectOnly(a)..addColumns([a.id]);
    unreadQuery.join([
      innerJoin(
        p,
        p.id.equalsExp(a.priorityId) &
            (p.path.equalsValue(priorityPath) |
                p.path.likeExp(Constant(priorityPathLike))),
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

  /// Watches icon value counts for non-archived threads in a priority subtree.
  static Stream<List<(String, int)>> watchIconCountsForPriority(
    Path priorityPath,
  ) {
    final a = Store.get.threads;
    final p = Store.get.priorities;
    final priorityPathLike = '$priorityPath.%';

    final query = Store.get.selectOnly(a)
      ..addColumns([a.icon, a.id.count()])
      ..join([
        innerJoin(
          p,
          p.id.equalsExp(a.priorityId) &
              (p.path.equalsValue(priorityPath) |
                  p.path.likeExp(Constant(priorityPathLike))),
        ),
      ])
      ..where(a.archivedAt.isNull() & a.draft.equals(false))
      ..groupBy([a.icon]);

    return query.watch().map((rows) {
      return rows
          .map((row) {
            final icon = row.read(a.icon);
            final count = row.read(a.id.count());
            if (icon == null || count == null) return null;
            return (icon, count);
          })
          .whereType<(String, int)>()
          .toList();
    });
  }

  static Future<List<Thread>> _get({
    DateRange? range,
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
    String? search,
    List<Tag>? filter,
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
      strictRange: strictRange,
      id: id,
      priorityId: priorityId,
      priorityPath: priorityPath,
      self: self,
      archived: archived,
      draft: draft,
      includeAllFutureEvents: includeAllFutureEvents,
      includeUnscheduled: includeUnscheduled,
      search: search,
      contactIdMatchesPerWord: contactIdMatchesPerWord,
      filter: filter,
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
    String? search,
    /// Per-search-word lists of actor UUID strings whose name has a word
    /// starting with that search word (resolved via [Actor.idsMatchingWordPrefix]).
    /// When non-null and aligned with the sanitized search words, the search
    /// clause also matches threads whose `contacts` column includes one of
    /// the listed actors per word (ANDed across words). Resolved by
    /// [_resolveContactIdMatches] before the query is built.
    List<List<String>>? contactIdMatchesPerWord,
    List<Tag>? filter,
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
    final userSched = Store.get.alias(Store.get.schedules, 'user_sched');
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
      // Shared schedule (event timing, visible to all priority members)
      leftOuterJoin(
        sched,
        sched.threadId.equalsExp(a.id) & sched.userId.isNull(),
      ),
      // Per-user schedule (todo state, dates, and order for current user)
      leftOuterJoin(
        userSched,
        userSched.threadId.equalsExp(a.id) &
            userSched.userId.equalsValue(Base.userId) &
            userSched.occurrence.isNull(),
      ),
      // Links for this thread, then their shared schedules
      leftOuterJoin(linkTable, linkTable.threadId.equalsExp(a.id)),
      leftOuterJoin(
        linkSched,
        linkSched.linkId.equalsExp(linkTable.id) & linkSched.userId.isNull(),
      ),
    ]);
    final now = DateTime.now();

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
      // Join conditions for priority path matching
      Expression<bool> pathCondition =
          p.path.equalsValue(priorityPath) |
          p.path.likeExp(Constant('$priorityPath%'));

      if (includeAllFutureEvents) {
        pathCondition =
            pathCondition |
            sched.endAt.isBiggerOrEqualValue(now) |
            userSched.endAt.isBiggerOrEqualValue(now) |
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
            // Per-user todo: non-archived per-user schedule exists
            (userSched.id.isNotNull() & userSched.archivedAt.isNull()) |
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
      query.where(
        a.unread.equals(true) &
            a.readAt.isNull(),
      );
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

      final ftsWords = sanitizedWords.map((word) => '$word*').join(' ');

      if (ftsWords.isNotEmpty) {
        // Each word must appear in either link title or source_url
        final linkConditions = sanitizedWords
            .map(
              (word) =>
                  "(ll.title LIKE '%$word%' OR ll.source_url LIKE '%$word%')",
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

        query.where(
          CustomExpression<bool>('''
            EXISTS (SELECT 1 FROM thread_fts WHERE thread_id = a.id AND thread_fts MATCH '$ftsWords')
            OR
            EXISTS (SELECT 1 FROM note_fts WHERE thread_id = a.id AND note_fts MATCH '$ftsWords')
            OR
            EXISTS (SELECT 1 FROM links ll WHERE ll.thread_id = a.id AND $linkConditions)
            ${contactBranch != null ? 'OR ($contactBranch)' : ''}
          '''),
        );
      }
    }
    if (iconFilter != null && iconFilter.isNotEmpty) {
      query.where(a.icon.isIn(iconFilter));
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
      // Must check both shared and per-user schedules have no dates.
      // Excluded for agenda queries where unscheduled non-todo items would
      // consume the LIMIT and then be filtered out as past dates.
      if (includeUnscheduled) {
        Expression<bool> unscheduled =
            sched.startOn.isNull() &
            sched.startAt.isNull() &
            userSched.startOn.isNull() &
            userSched.startAt.isNull();
        condition = condition | unscheduled;
      }

      // Active todo: always include threads with an active user schedule (has dates).
      // Skip for linkScheduledOnly — we only want threads by their link schedule,
      // not by their user schedule (those belong to the priority-filtered query).
      if (!linkScheduledOnly) {
        Expression<bool> activeTodo =
            userSched.id.isNotNull() &
            userSched.archivedAt.isNull() &
            (userSched.startOn.isNotNull() | userSched.startAt.isNotNull());
        condition = condition | activeTodo;
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

        // Per-user schedule date-based
        Expression<bool> userDateScheduled = userSched.startOn.isNotNull();
        if (range.start != null) {
          if (strictRange) {
            userDateScheduled =
                userDateScheduled &
                userSched.startOn.isBiggerOrEqualValue(range.start!.toString());
          } else {
            userDateScheduled =
                userDateScheduled &
                (userSched.endOn.isNull() |
                    userSched.endOn.isBiggerOrEqualValue(
                      range.start!.toString(),
                    ));
          }
        }
        if (range.end != null) {
          userDateScheduled =
              userDateScheduled &
              userSched.startOn.isSmallerThanValue(range.end!.toString());
        }
        condition = condition | userDateScheduled;
      }

      // Activity is scheduled within the range (DateTime-based)
      // Shared schedule
      Expression<bool> dateTimeScheduled = sched.startAt.isNotNull();
      if (rangeStart != null) {
        if (strictRange) {
          dateTimeScheduled =
              dateTimeScheduled &
              sched.startAt.isBiggerOrEqualValue(rangeStart);
        } else {
          dateTimeScheduled =
              dateTimeScheduled &
              (sched.endAt.isNull() |
                  sched.endAt.isBiggerOrEqualValue(rangeStart));
        }
      }
      if (rangeEnd != null) {
        dateTimeScheduled =
            dateTimeScheduled & sched.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | dateTimeScheduled;

      // Per-user schedule datetime-based
      Expression<bool> userDateTimeScheduled = userSched.startAt.isNotNull();
      if (rangeStart != null) {
        if (strictRange) {
          userDateTimeScheduled =
              userDateTimeScheduled &
              userSched.startAt.isBiggerOrEqualValue(rangeStart);
        } else {
          userDateTimeScheduled =
              userDateTimeScheduled &
              (userSched.endAt.isNull() |
                  userSched.endAt.isBiggerOrEqualValue(rangeStart));
        }
      }
      if (rangeEnd != null) {
        userDateTimeScheduled =
            userDateTimeScheduled &
            userSched.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | userDateTimeScheduled;

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
      if (rangeStart != null) {
        if (strictRange) {
          linkDateTimeScheduled =
              linkDateTimeScheduled &
              linkSched.startAt.isBiggerOrEqualValue(rangeStart);
        } else {
          linkDateTimeScheduled =
              linkDateTimeScheduled &
              (linkSched.endAt.isNull() |
                  linkSched.endAt.isBiggerOrEqualValue(rangeStart));
        }
      }
      if (rangeEnd != null) {
        linkDateTimeScheduled =
            linkDateTimeScheduled &
            linkSched.startAt.isSmallerThanValue(rangeEnd);
      }
      condition = condition | linkDateTimeScheduled;

      // Exclude archived per-user schedules (done items).
      // Only include threads where the user schedule is absent, not archived,
      // or has a link schedule.
      condition =
          condition &
          (userSched.id.isNull() |
              userSched.archivedAt.isNull() |
              linkSched.id.isNotNull());

      query.where(condition);
    }

    if (limit != null) {
      query.limit(limit, offset: offset);
    }

    switch (order) {
      case ThreadOrder.sorted:
        // Todo list: schedule-based sorting (check shared then per-user then link)
        final todoSort = CaseWhenExpression(
          cases: [
            CaseWhen(sched.startAt.isNotNull(), then: sched.startAt),
            CaseWhen(sched.startOn.isNotNull(), then: sched.startOn),
            CaseWhen(userSched.startAt.isNotNull(), then: userSched.startAt),
            CaseWhen(userSched.startOn.isNotNull(), then: userSched.startOn),
            CaseWhen(linkSched.startAt.isNotNull(), then: linkSched.startAt),
            CaseWhen(linkSched.startOn.isNotNull(), then: linkSched.startOn),
          ],
          orElse: Constant(DateTime.utc(0)),
        );
        query.orderBy([
          OrderingTerm.asc(todoSort),
          OrderingTerm.asc(userSched.order),
        ]);
        break;
      case ThreadOrder.reverse:
        // Activity feed: GREATEST(lastNoteSourceCreatedAt, linkSourceCreatedAt, bumpedAt, pastScheduleEnd)
        // Falls back to createdAt only when all are null.
        final epoch = Constant(DateTime.fromMillisecondsSinceEpoch(0));
        final now = DateTime.now();
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

        final unreadSort =
            a.unread.equals(true) &
            a.readAt.isNull();

        query.orderBy([
          OrderingTerm.desc(unreadSort),
          OrderingTerm.desc(feedSort),
        ]);
        break;
    }

    // Add join for tags (sched already joined above)
    final tags = Store.get.alias(Store.get.threadTags, 'tags');

    query = query.join([
      leftOuterJoin(
        tags,
        (tags.id.equalsExp(a.id) | (tags.id.isNull() & a.id.isNull())) &
            (tags.occurrence.equalsExp(sched.occurrence) |
                (tags.occurrence.equals('') & sched.occurrence.isNull())),
      ),
    ]);

    // Add tag filtering if filter list is provided
    // This must happen AFTER the tags table is joined
    if (mutableFilter != null && mutableFilter.isNotEmpty) {
      for (final tag in mutableFilter) {
        query.where(
          CustomExpression<bool>(
            'JSON_EXTRACT(tags.tags, \'\$.${tag.id}\') IS NOT NULL',
          ),
        );
      }
    }

    return query;
  }

  /// Efficiently gets which activity IDs from the given list are active.
  /// An activity is active if it's an action assigned to current user,
  /// not done, not archived, and scheduled for now/past or unscheduled.
  static Future<Set<ThreadId>> _getActiveThreadIds(List<ThreadId> ids) async {
    if (ids.isEmpty) return {};

    final now = DateTime.now();
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

    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.id]);

    // Convert ThreadId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.id.isIn(idBytes) &
          a.unread.equals(true) &
          a.readAt.isNull(),
    );

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
    final userSched = Store.get.alias(Store.get.schedules, 'user_sched');
    final linkTable = Store.get.alias(Store.get.links, 'l');
    final linkSched = Store.get.alias(Store.get.schedules, 'link_sched');

    // Get all priorities needed for the activities
    final priorities = await Priority.get(
      archived: null,
    );
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

      // Read the base schedule (first row without an occurrence, or just the first)
      final baseScheduleRow = group.first.readTableOrNull(sched);
      final userScheduleRow = group.first.readTableOrNull(userSched);

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
        final now = DateTime.now();
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
        userSchedule: userScheduleRow,
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
                userSchedule: userScheduleRow,
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
              userSchedule: userScheduleRow,
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
                  userSchedule: userScheduleRow,
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
                occurrences.values.where((occ) => !occ.isDeclinedByUser));
          } else {
            // Non-recurring link schedules: range-check and add individually.
            for (final linkScheduleRow in linkGroup) {
              if (linkScheduleRow.archivedAt != null) continue;
              final linkThread = Thread._fromStore(
                activity: activityRow,
                priority: priority,
                schedule: linkScheduleRow,
                userSchedule: userScheduleRow,
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
                userSchedule: thread._userSchedule,
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

  Thread({
    required this.priority,
    String? title,
    String? preview,
    bool draft = false,
    DateTimeRange? at,
    DateRange? on,
    List<Note>? notes,
  }) : _thread = ThreadRow(
         id: Uuid.generate(),
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         priorityId: priority.id,
         draft: draft,
         title: title,
         preview: preview,
         unread: false,
         importance: 0,
         urgency: null,
         readAt: null,
         hasEmbedding: false,
         // Seed topic + per-priority sharing defaults onto the draft thread so
         // it inherits the routing key, any auto-attached contacts/groups, and
         // pending email invites before the user types. When no explicit
         // config.topic is set, fall back to the priority id itself for
         // non-root priorities, so sibling threads filed in the same
         // sub-priority share a topic filter for classify_thread_for_user.
         topic: priority.priorityConfig.topic ??
             (priority.path.isRoot ? null : priority.id.toString()),
         contacts: priority.inheritedDefaultSharedContacts.isEmpty
             ? null
             : List<Uuid>.from(priority.inheritedDefaultSharedContacts),
         groups: priority.inheritedDefaultSharedGroups.isEmpty
             ? null
             : List<Uuid>.from(priority.inheritedDefaultSharedGroups),
         inviteEmails: priority.inheritedDefaultSharedInviteEmails.isEmpty
             ? null
             : jsonEncode(priority.inheritedDefaultSharedInviteEmails),
       ),
       _schedule = null,
       _userSchedule = null,
       _tags = null,
       _notes = notes,
       _active = null,
       _unreadComputed = null,
       _linkSourceCreatedAt = null,
       _activityDirty = true,
       _activityRemoteDirty = true,
       _scheduleDirty = true,
       isLinkScheduleInstance = false,
       rsvpInheritedFromSeries = false;

  Thread._fromStore({
    required ThreadRow activity,
    required this.priority,
    ScheduleRow? schedule,
    ScheduleRow? userSchedule,
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
  }) : _thread = activity,
       _schedule = schedule,
       _userSchedule = userSchedule,
       _tags = tags,
       _notes = notes,
       _active = active,
       _unreadComputed = unreadComputed,
       _linkSourceCreatedAt = linkSourceCreatedAt,
       _activityDirty = activityDirty,
       _activityRemoteDirty = activityRemoteDirty,
       _scheduleDirty = scheduleDirty {
    assert(
      priority.id == activity.priorityId,
      "Priority does not match activity",
    );
  }

  final ThreadRow _thread;
  final ScheduleRow? _schedule;
  final ScheduleRow? _userSchedule;
  final ThreadTagsRow? _tags;
  final List<Note>? _notes;
  final bool? _active;
  final bool? _unreadComputed;
  final DateTime? _linkSourceCreatedAt;
  final bool _activityDirty;
  /// Whether the activity row needs a remote push (vs local-only read-state update).
  final bool _activityRemoteDirty;
  final bool _scheduleDirty;

  /// Whether this instance represents a link schedule (event from a linked item).
  /// Link schedule instances appear at their event time and are not reorderable.
  final bool isLinkScheduleInstance;

  /// Whether the RSVP status shown on [_schedule] was inherited from the
  /// series row rather than set on this specific occurrence. Used by
  /// [ToggleRsvp] to decide whether a toggle should target the series or
  /// the occurrence. Defaults to false. Set to true only by
  /// [loadRepresentativeForFeed] when it resolves a recurring event to a
  /// representative occurrence whose RSVP is a series-level copy.
  final bool rsvpInheritedFromSeries;

  final Priority priority;

  Uuid get id => _thread.id;
  bool get recurring =>
      (_schedule?.recurrenceRule ?? _userSchedule?.recurrenceRule) != null &&
      (_schedule?.occurrence ?? _userSchedule?.occurrence) == null;
  Order get order => _userSchedule?.order ?? Order.first();
  DateTime get createdAt => _thread.createdAt;
  DateTime get updatedAt => _thread.updatedAt;
  DateTime? get archivedAt => _thread.archivedAt;
  bool get draft => _thread.draft;
  List<Uuid> get contacts => _thread.contacts ?? const [];
  List<Uuid> get groups => _thread.groups ?? const [];
  String? get topic => _thread.topic;
  /// Pending email invitations that haven't been synced yet.
  List<String> get inviteEmails {
    final raw = _thread.inviteEmails;
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }
  DateTime? get lastNoteCreatedAt => _thread.lastNoteCreatedAt;
  DateTime? get lastNoteSourceCreatedAt => _thread.lastNoteSourceCreatedAt;
  RecurrenceRule? get recurrenceRule =>
      _schedule?.recurrenceRule ?? _userSchedule?.recurrenceRule;
  List<DateTime>? get recurrenceExdates =>
      _schedule?.recurrenceExdates ?? _userSchedule?.recurrenceExdates;
  Map<Tag, List<ActorId>> get tags => {
    ...Map.fromEntries(
      [
        Tag.todo,
        Tag.archived,
        Tag.private,
      ].where((tag) => hasTag(tag)).map((tag) => MapEntry(tag, [Base.actorId])),
    ),
    ...(_tags?.tags ?? const {}),
  };

  /// Returns true if this activity is active (computed from query or false if not computed)
  bool get active => _active ?? false;

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
  DateTime get contentTimestamp =>
      lastNoteSourceCreatedAt ?? createdAt;
  String? get urgency => _thread.urgency;
  int get importance => _thread.importance;

  int get urgencyRank => switch (urgency) {
    'interrupt' => 0,
    'inform-requests' => 1,
    'inform-updates' => 2,
    'passive' => 3,
    _ => 4,
  };

  String? get title => _thread.title;
  String? get preview => _thread.preview;
  String? get icon => _thread.icon;
  bool get hasEmbedding => _thread.hasEmbedding;

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
      return (
        logoUrl: null,
        logoDarkUrl: null,
        fallbackIcon: PlotIcon.notes,
      );
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
            final channelConfig = Channel.findBySource(pt.id)
                ?.parsedLinkTypes
                ?.where((c) => c.type == type)
                .firstOrNull;
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
    return (
      logoUrl: null,
      logoDarkUrl: null,
      fallbackIcon: PlotIcon.notes,
    );
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
      // Strip markdown so mentions like [Name](#@UUID) display as plain text.
      // Keep in sync with stripMarkdown() in workers/api thread-helpers.ts.
      return preview?.removeMarkdown(replaceLinksWithURL: false);
    }
    if (preview == null) return null;
    final derivedTitle = _titleFromContent(preview);
    if (derivedTitle == null) return null;
    return _remainderPreview(preview!, derivedTitle);
  }

  /// Derives a display title from content (preview or note body).
  /// Strips markdown, takes the first line, truncates at word boundary if > 60 chars.
  static String? _titleFromContent(String? content) {
    if (content == null || content.trim().isEmpty) return null;
    final stripped = content.removeMarkdown(replaceLinksWithURL: false);
    final firstLine = stripped.split('\n').first.trim();
    if (firstLine.isEmpty) return null;
    if (firstLine.length <= 60) return firstLine;
    final lastSpace = firstLine.lastIndexOf(' ', 60);
    if (lastSpace > 0) {
      return '${firstLine.substring(0, lastSpace)}\u2026';
    }
    return '${firstLine.substring(0, 59)}\u2026';
  }

  /// Returns the portion of preview after the derived title.
  static String? _remainderPreview(String preview, String derivedTitle) {
    String prefix = derivedTitle;
    if (prefix.endsWith('\u2026')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    final stripped = preview.removeMarkdown(replaceLinksWithURL: false);
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
        (_userSchedule?.startAt != null && _userSchedule!.archivedAt == null
            ? DateTimeRange(_userSchedule.startAt!, _userSchedule.endAt)
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
        (_userSchedule?.startOn != null &&
                _userSchedule!.archivedAt == null &&
                _userSchedule.startOn != Thread.todoNowDate
            ? CustomDateRange(_userSchedule.startOn!, _userSchedule.endOn)
            : null);
  }

  Duration? get duration {
    if (isLinkScheduleInstance) {
      return _schedule?.duration ?? on?.duration ?? at?.duration;
    }
    return _schedule?.duration ??
        _userSchedule?.duration ??
        on?.duration ??
        at?.duration;
  }

  DateTime get agendaAt {
    if (isLinkScheduleInstance) {
      // Link schedule instances always appear at their schedule time
      return at?.start ?? on?.start?.toDateTime() ?? createdAt;
    }
    if (todo) {
      // User schedule date takes priority (explicit user override via reorder).
      final schedDate =
          _userSchedule?.startOn?.toDateTime() ??
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

  /// Original schedule date for todo sorting. Unlike agendaAt, this preserves
  /// past dates so that todos from different days maintain their relative order
  /// when they all appear as "current".
  DateTime get todoSortDate {
    return _userSchedule?.startOn?.toDateTime() ??
        pinnedAfterTime ??
        at?.start ??
        on?.start?.toDateTime() ??
        createdAt;
  }

  /// Compare todos by original schedule date first, then by order.
  int todoCompareTo(Thread other) {
    final dateComp = todoSortDate.compareTo(other.todoSortDate);
    if (dateComp != 0) return dateComp;
    return order.compareTo(other.order);
  }

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

    final now = DateTime.now();

    if (!recurring) {
      // Non-recurring: use the schedule end time directly
      final end = _schedule.endAt ?? _schedule.endOn?.toDateTime();
      return (end != null && end.isBefore(now)) ? end : null;
    }

    // Recurring: find the last occurrence that has ended before now
    final start = (at?.start ?? on?.start?.toDateTime());
    if (start == null || recurrenceRule == null) return null;

    try {
      final instances = recurrenceRule!.getInstances(
        start: start.copyWith(isUtc: true),
        after: start.copyWith(isUtc: true),
        includeAfter: true,
        before: now.copyWith(isUtc: true),
      );

      DateTime? lastInstance;
      for (final instance in instances) {
        lastInstance = instance.copyWith(isUtc: false);
      }

      if (lastInstance != null && duration != null) {
        final end = lastInstance.add(duration!);
        if (end.isBefore(now)) return end;
      }
    } catch (_) {
      // Silently handle invalid RRULEs
    }

    return null;
  }

  bool get todo =>
      _userSchedule != null &&
      _userSchedule.archivedAt == null &&
      (_userSchedule.startOn != null || _userSchedule.startAt != null);

  /// Returns the pinned-after time for a todo that was dragged after an event.
  /// A todo is "pinned" when it has a userSchedule.startAt but no real startOn
  /// (null or epoch sentinel). Returns null for regular todos/events.
  DateTime? get pinnedAfterTime {
    if (_userSchedule == null) return null;
    final startAt = _userSchedule.startAt;
    if (startAt == null) return null;
    final startOn = _userSchedule.startOn;
    if (startOn == null || startOn == Thread.todoNowDate) return startAt;
    return null;
  }

  /// Whether this todo is pinned after a specific event.
  bool get isPinnedTodo => pinnedAfterTime != null;

  /// A thread is "done" when it has no active per-user schedule (archived or absent)
  /// and no dates set. Effectively: not a todo.
  bool get done => _userSchedule != null && !todo;
  bool get outstandingTasks => _userSchedule?.outstandingTasks ?? false;
  DateTime? get bumpedAt => _thread.bumpedAt;
  bool get hasUserSchedule => _userSchedule != null;
  bool get isPast =>
      at?.end?.isBefore(Time.now()) == true ||
      on?.end?.isBefore(Date.today()) == true;
  bool get isFuture {
    if (isLinkScheduleInstance) {
      // Icon based on user schedule state only, not the link schedule's date
      if (_userSchedule?.startOn != null) {
        return _userSchedule!.startOn!.isAfter(Date.today());
      }
      return false; // No user date = not future = shows todo icon
    }
    // For todos, check the user schedule date first (matches agendaAt logic)
    // so the icon is consistent with the date the thread appears under.
    if (todo && _userSchedule?.startOn != null) {
      return _userSchedule!.startOn!.isAfter(Date.today());
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

  /// The current user's RSVP status on this schedule ('attend', 'skip', or null).
  String? get currentUserRsvp => _schedule?.currentUserStatus;

  /// Whether the current user has effectively declined this schedule.
  /// True when at least one of the user's contacts has 'skip' and none have 'attend'.
  bool get isDeclinedByUser {
    final contacts = scheduleContacts;
    if (contacts.isEmpty) return false;
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
      userSchedule: _userSchedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      scheduleDirty: true,
    );
  }

  static const separator = ' › ';

  /// Returns a new Thread with the given user schedule, preserving all other fields.
  Thread _withUserSchedule(ScheduleRow userSchedule) {
    return Thread._fromStore(
      activity: _thread,
      schedule: _schedule,
      userSchedule: userSchedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
    );
  }

  /// Returns a copy with [isLinkScheduleInstance] set to false.
  /// Used for optimistic insertion of the base todo duplicate when starting
  /// a link schedule thread.
  Thread toBaseTodo() {
    return Thread._fromStore(
      activity: _thread,
      schedule: _schedule,
      userSchedule: _userSchedule,
      tags: _tags,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: false,
      rsvpInheritedFromSeries: false,
    );
  }

  /// Reorder this thread. Updates the per-user schedule order.
  /// Shared schedules cannot have order (DB constraint: schedule_order_user).
  Thread reorder(Order order) {
    if (_userSchedule != null) {
      final result = _withUserSchedule(
        _userSchedule.copyWith(order: Value(order), updatedAt: DateTime.now()),
      );
      log.info(
        '[reorder] "$title" order: ${_userSchedule.order?.value} -> $order '
        '(schedId=${_userSchedule.id.toShortString()})',
      );
      return result;
    }
    log.warning('[reorder] "$title" has no userSchedule — cannot reorder');
    return this;
  }

  /// Reorder this thread to a different day. Updates order AND schedule date.
  /// [date] null → sets epoch sentinel (Now/current todo).
  /// [date] someDate → schedules for that date, clears time fields.
  Thread reorderTo(Order order, {required Date? date}) {
    if (_userSchedule != null) {
      final result = _withUserSchedule(
        _userSchedule.copyWith(
          order: Value(order),
          startOn: Value(date ?? Thread.todoNowDate),
          endOn: const Value(null),
          startAt: const Value(null),
          endAt: const Value(null),
          updatedAt: DateTime.now(),
          reason: Value(date != null ? 'schedule' : _userSchedule.reason),
        ),
      );
      log.info(
        '[reorderTo] "$title" order: ${_userSchedule.order?.value} -> $order '
        'date: ${_userSchedule.startOn} -> $date '
        '(schedId=${_userSchedule.id.toShortString()})',
      );
      return result;
    }
    log.warning('[reorderTo] "$title" has no userSchedule — cannot reorder');
    return this;
  }

  /// Pin this todo after a specific event. Sets startAt = event end time,
  /// clears startOn/endOn/endAt so the todo appears after that event on today.
  Thread reorderToAfterEvent(Order order, {required DateTime eventEndTime}) {
    if (_userSchedule != null) {
      final result = _withUserSchedule(
        _userSchedule.copyWith(
          order: Value(order),
          startAt: Value(eventEndTime),
          startOn: const Value(null),
          endOn: const Value(null),
          endAt: const Value(null),
          updatedAt: DateTime.now(),
          reason: const Value('schedule'),
        ),
      );
      log.info(
        '[reorderToAfterEvent] "$title" order: ${_userSchedule.order?.value} -> $order '
        'pinned after: $eventEndTime '
        '(schedId=${_userSchedule.id.toShortString()})',
      );
      return result;
    }
    log.warning(
      '[reorderToAfterEvent] "$title" has no userSchedule — cannot reorder',
    );
    return this;
  }

  /// Associate this thread with a parent event thread.
  /// Archives the user schedule and creates a shared association.
  Future<void> associateWith({
    required Uuid parentThreadId,
    required Order order,
  }) async {
    log.info(
      '[associateWith] "$title" -> parent=$parentThreadId order=${order.value}',
    );

    // Archive any existing active association for this child thread
    // (a child can only be associated with one parent at a time).
    final existing = await (Store.get.select(Store.get.threadAssociations)
          ..where((t) => t.childThreadId.equals(id.toBytes()))
          ..where((t) => t.archivedAt.isNull()))
        .get();

    for (final assoc in existing) {
      if (assoc.parentThreadId == parentThreadId) {
        // Same parent — just update the order
        await Store.get.save(
          Store.get.threadAssociations,
          assoc.copyWith(order: order, updatedAt: DateTime.now())
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

    // Archive the user schedule (remove from personal agenda)
    if (_userSchedule != null) {
      final archivedSchedule = _userSchedule.copyWith(
        archivedAt: Value(DateTime.now()),
        updatedAt: DateTime.now(),
      );
      await Store.get.save(
        Store.get.schedules,
        archivedSchedule.toCompanion(false),
        SchedulesBase(),
      );
    }

    Thread.push();
  }

  /// Remove association and restore the user schedule.
  Future<void> disassociate({
    required Order order,
    Date? date,
  }) async {
    log.info('[disassociate] "$title" order=${order.value} date=$date');

    // Archive the active association for this child thread
    final associations = await (Store.get.select(Store.get.threadAssociations)
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

    // Restore or create a user schedule
    if (_userSchedule != null) {
      final restoredSchedule = _userSchedule.copyWith(
        archivedAt: const Value(null),
        order: Value(order),
        startOn: Value(date ?? Thread.todoNowDate),
        startAt: const Value(null),
        endAt: const Value(null),
        endOn: const Value(null),
        updatedAt: DateTime.now(),
        reason: Value(date != null ? 'schedule' : 'add'),
      );
      await Store.get.save(
        Store.get.schedules,
        restoredSchedule.toCompanion(false),
        SchedulesBase(),
      );
    } else {
      final newSchedule = ScheduleRow(
        id: Uuid.generate(),
        updatedAt: DateTime.now(),
        threadId: id,
        userId: Base.userId,
        startOn: date ?? Thread.todoNowDate,
        order: order,
        outstandingTasks: false,
        reason: date != null ? 'schedule' : 'add',
      );
      await Store.get.save(
        Store.get.schedules,
        newSchedule.toCompanion(false),
        SchedulesBase(),
      );
    }

    Thread.push();
  }

  /// Reorder within an association group (shared order).
  Future<void> reorderAssociation(Order order) async {
    log.info('[reorderAssociation] "$title" order=${order.value}');

    final associations = await (Store.get.select(Store.get.threadAssociations)
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
      log.warning(
        '[reorderAssociation] "$title" has no active association',
      );
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

  Thread copyWith({
    // These fields always update the root activity
    Priority? priority,
    Order? order,
    bool? draft,
    Value<List<Uuid>?> contacts = const Value.absent(),
    Value<List<Uuid>?> groups = const Value.absent(),
    Value<List<String>?> inviteEmails = const Value.absent(),
    bool? unread,
    Value<String?> preview = const Value.absent(),
    Value<String?> icon = const Value.absent(),
    Value<List<Note>?> notes = const Value.absent(),

    // These fields update the exception if this is a recurrence, or the root activity otherwise
    Value<DateTimeRange?> at = const Value.absent(),
    Value<DateRange?> on = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Value<Duration?> duration = const Value.absent(),
    Value<DateTime?> archivedAt = const Value.absent(),

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
        groups.present ||
        inviteEmails.present ||
        unread != null ||
        preview.present ||
        icon.present ||
        archivedAt.present ||
        bumpedAt.present ||
        readAt.present ||
        title.present) {
      activityDirty = true;
      // Read-state fields (unread, readAt, bumpedAt) sync via
      // /sync/thread-unread, not the regular thread push. Only mark remote
      // dirty when non-read-state fields change.
      activityRemoteDirty = priority != null ||
          draft != null ||
          contacts.present ||
          groups.present ||
          inviteEmails.present ||
          preview.present ||
          icon.present ||
          archivedAt.present ||
          title.present;
      activity = _thread.copyWith(
        priorityId: priority?.id,
        draft: draft,
        contacts: contacts,
        groups: groups,
        inviteEmails: inviteEmails.present
            ? Value(inviteEmails.value != null && inviteEmails.value!.isNotEmpty
                ? jsonEncode(inviteEmails.value)
                : null)
            : const Value.absent(),
        preview: preview,
        icon: icon,
        createdAt: draft == false && _thread.draft ? now : null,
        updatedAt: now,
        archivedAt: archivedAt,
        bumpedAt: bumpedAt,
        readAt: readAt,
        title: !recurring ? title : const Value.absent(),
        unread: unread,
      );
    }

    // Update schedule if scheduling fields are changing
    var schedule = _schedule;
    var userSchedule = _userSchedule;

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
        Value<Order?> schedOrder = const Value.absent();

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
        // Only set order on per-user schedules (DB constraint: schedule_order_user)
        if (order != null && schedule.userId != null) schedOrder = Value(order);

        schedule = schedule.copyWith(
          startAt: schedStartAt,
          endAt: schedEndAt,
          startOn: schedStartOn,
          endOn: schedEndOn,
          duration: schedDuration,
          recurrenceRule: recurrenceRule,
          recurrenceExdates: recurrenceExdates,
          order: schedOrder,
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
        // Create or update per-user schedule with date data (for to-dos)
        if (userSchedule != null) {
          // Update existing per-user schedule with new dates
          userSchedule = userSchedule.copyWith(
            startAt: at.present ? Value(at.value?.start) : const Value.absent(),
            endAt: at.present ? Value(at.value?.end) : const Value.absent(),
            startOn: on.present ? Value(on.value?.start) : const Value.absent(),
            endOn: on.present ? Value(on.value?.end) : const Value.absent(),
            duration: duration,
            recurrenceRule: recurrenceRule,
            recurrenceExdates: recurrenceExdates,
            order: order != null ? Value(order) : const Value.absent(),
            updatedAt: now,
          );
        } else {
          // Create new per-user schedule with date data
          userSchedule = ScheduleRow(
            id: Uuid.generate(),
            updatedAt: now,
            threadId: _thread.id,
            userId: Base.userId,
            startAt: at.present ? at.value?.start : null,
            endAt: at.present ? at.value?.end : null,
            startOn: on.present ? on.value?.start : null,
            endOn: on.present ? on.value?.end : null,
            duration: duration.present ? duration.value : null,
            recurrenceRule: recurrenceRule.present
                ? recurrenceRule.value
                : null,
            recurrenceExdates: recurrenceExdates.present
                ? recurrenceExdates.value
                : null,
            order: order ?? Order.first(),
            outstandingTasks: false,
          );
        }
      }
    }

    // Clear dates on per-user schedule when shared schedule is intentionally removed
    if (schedule == null && _schedule != null && userSchedule != null) {
      userSchedule = userSchedule.copyWith(
        startOn: const Value(null),
        endOn: const Value(null),
        startAt: const Value(null),
        endAt: const Value(null),
      );
    }

    // Handle personal to-do state
    if (todo == true) {
      if (userSchedule != null) {
        userSchedule = userSchedule.copyWith(
          startOn: Value(Thread.todoNowDate),
          order: Value(Order.first()),
          archivedAt: const Value(null),
          reason: const Value('add'),
        );
      } else {
        userSchedule = ScheduleRow(
          id: Uuid.generate(),
          updatedAt: now,
          threadId: _thread.id,
          userId: Base.userId,
          startOn: Thread.todoNowDate,
          order: Order.first(),
          reason: 'add',
          outstandingTasks: false,
        );
      }
    }

    // Set reason='schedule' when user explicitly sets dates on a per-user schedule
    if (userSchedule != null &&
        (at.present || on.present) &&
        todo != true &&
        todo != false) {
      userSchedule = userSchedule.copyWith(reason: const Value('schedule'));
    }

    if (todo == false) {
      // Mark done: archive the user schedule (clear dates, set archived_at)
      if (userSchedule != null) {
        userSchedule = userSchedule.copyWith(
          archivedAt: Value(DateTime.now()),
          startOn: const Value(null),
          startAt: const Value(null),
          endOn: const Value(null),
          endAt: const Value(null),
        );
      } else {
        userSchedule = ScheduleRow(
          id: Uuid.generate(),
          updatedAt: now,
          threadId: _thread.id,
          userId: Base.userId,
          order: Order.first(),
          archivedAt: DateTime.now(),
          outstandingTasks: false,
        );
      }
    }

    // Set bumpedAt on the thread when bumping (agenda done)
    // Also trigger thread-read sync so bumped_at gets pushed
    if (bump && todo == false) {
      activityDirty = true;
      activity = activity.copyWith(
        bumpedAt: Value(DateTime.now()),
        unread: false,
        readAt: Value(contentTimestamp),
      );
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
      userSchedule: userSchedule,
      tags: _tags,
      priority: priority ?? this.priority,
      notes: notes.present ? notes.value : _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      unreadComputed: unread != null ? null : _unreadComputed,
      activityDirty: activityDirty,
      activityRemoteDirty: activityRemoteDirty,
      scheduleDirty: scheduleDirty,
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
          // Remove from todo: clear dates
          return _withUserSchedule(
            _userSchedule!.copyWith(
              startOn: const Value(null),
              startAt: const Value(null),
              endOn: const Value(null),
              endAt: const Value(null),
            ),
          );
        } else if (_userSchedule != null) {
          // Re-add to todo: unarchive and set epoch sentinel
          return _withUserSchedule(
            _userSchedule.copyWith(
              startOn: Value(Thread.todoNowDate),
              order: Value(Order.first()),
              archivedAt: const Value(null),
              reason: const Value('add'),
            ),
          );
        } else {
          return _withUserSchedule(
            ScheduleRow(
              id: Uuid.generate(),
              updatedAt: DateTime.now(),
              threadId: id,
              userId: Base.userId,
              startOn: Thread.todoNowDate,
              order: Order.first(),
              reason: 'add',
              outstandingTasks: false,
            ),
          );
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
      // Count behavior: add/remove current user while preserving other users
      if (currentUsers.contains(currentUser)) {
        // Remove current user from tag
        currentUsers.remove(currentUser);
        if (currentUsers.isEmpty) {
          currentTags.remove(tag);
        } else {
          currentTags[tag] = currentUsers;
        }
        isAdding = false; // Removing the user's count
      } else {
        // Add current user to tag (increment count)
        currentUsers.add(currentUser);
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
      userSchedule: _userSchedule,
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
      final target = config.statuses?.where((s) => s.todo).firstOrNull ??
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
    final currentTags =
        Map<Tag, List<ActorId>>.from(_tags?.tags ?? const {});
    final currentTagUpdates =
        Map<String, bool>.from(_tags?.tagsUpdated ?? {});
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

    // 5. Build the new user schedule (same rules as toggleTag(Tag.todo) add).
    final ScheduleRow newUserSchedule;
    if (_userSchedule != null) {
      newUserSchedule = _userSchedule.copyWith(
        startOn: Value(Thread.todoNowDate),
        order: Value(Order.first()),
        archivedAt: const Value(null),
        reason: const Value('add'),
        updatedAt: now,
      );
    } else {
      newUserSchedule = ScheduleRow(
        id: Uuid.generate(),
        updatedAt: now,
        threadId: id,
        userId: Base.userId,
        startOn: Thread.todoNowDate,
        order: Order.first(),
        reason: 'add',
        outstandingTasks: false,
      );
    }

    // 6. Clear thread.archivedAt if set.
    final wasArchived = _thread.archivedAt != null;
    final newActivity = wasArchived
        ? _thread.copyWith(
            archivedAt: const Value(null),
            updatedAt: now,
          )
        : _thread;

    // 7. Build the new tags row (only if anything actually changed).
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
              tagsUpdated:
                  currentTagUpdates.isEmpty ? null : currentTagUpdates,
            ))
        : _tags;

    return Thread._fromStore(
      activity: newActivity,
      schedule: _schedule,
      userSchedule: newUserSchedule,
      tags: newTagsRow,
      priority: priority,
      notes: _notes,
      isLinkScheduleInstance: isLinkScheduleInstance,
      rsvpInheritedFromSeries: rsvpInheritedFromSeries,
      activityDirty: wasArchived,
      activityRemoteDirty: wasArchived,
    );
  }

  /// Save only the schedule that was changed by [reorder].
  /// Avoids unnecessary re-emissions from unchanged rows.
  Future<void> saveOrder() async {
    if (_userSchedule != null) {
      log.info(
        '[saveOrder] "$title" saving userSchedule '
        '(schedId=${_userSchedule.id.toShortString()}, '
        'order=${_userSchedule.order?.value})',
      );
      await Store.get.save(
        Store.get.schedules,
        _userSchedule.toCompanion(false),
        SchedulesBase(),
      );
    } else {
      log.warning('[saveOrder] "$title" has no userSchedule — nothing to save');
    }
    Thread.push();
  }

  /// Insert this thread's row into the local DB if it doesn't already
  /// exist. Used for new in-memory drafts on first content edit, where
  /// only the note has changed and a regular [save] would skip the row
  /// (because [_activityDirty] is false). Without this, the thread row
  /// never lands locally and chain/priority draft lookups can't find it.
  Future<void> ensurePersisted() async {
    if (!Store.isAvailable) return;
    await Store.get.into(Store.get.threads).insert(
      _thread.toCompanion(false),
      mode: InsertMode.insertOrIgnore,
    );
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
        // Local-only update for read-state fields (unread, readAt, etc.).
        // These sync via /sync/thread-unread, not the regular thread push.
        // Use update().write() to avoid setting pending (which would trigger
        // a full thread sync that fails for viewer members).
        await (Store.get.update(Store.get.threads)
              ..where((a) => a.id.equalsValue(id)))
            .write(ThreadsCompanion(
              unread: Value(_thread.unread),
              importance: Value(_thread.importance),
              urgency: Value(_thread.urgency),
              readAt: Value(_thread.readAt),
              bumpedAt: Value(_thread.bumpedAt),
              updatedAt: Value(_thread.updatedAt),
            ));
      }
    } else {
      // Thread row wasn't written — ensure it exists in the local DB so
      // the draft filter can correctly exclude child rows (schedules, tags)
      // from being pushed before the thread itself. Uses insertOrIgnore so
      // an existing row (and its pending flag) is never overwritten.
      final hasChildRows = _userSchedule != null ||
          _tags != null ||
          (_scheduleDirty && _schedule != null && _schedule.linkId == null);
      if (hasChildRows) {
        await Store.get.into(Store.get.threads).insert(
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
        await (Store.get.update(Store.get.schedules)
              ..where((a) => a.id.equalsValue(_schedule.id)))
            .write(SchedulesCompanion(
              contacts: Value(_schedule.contacts),
              currentUserStatus: Value(_schedule.currentUserStatus),
              updatedAt: Value(DateTime.now()),
            ));
      }
    }
    if (_userSchedule != null) {
      await Store.get.save(
        Store.get.schedules,
        _userSchedule.toCompanion(false),
        SchedulesBase(),
      );
    }
    if (_tags != null) {
      await Store.get.save(
        Store.get.threadTags,
        _tags.toCompanion(false),
        ThreadTagsBase(),
      );
    }

    // Trigger full push including activity_read changes (fire and forget)
    // This ensures activity_read is synced immediately, not just during sync cycles
    Thread.push();

    // Generate AI title on first non-draft save. Fire-and-forget so callers
    // (e.g. NewThreadPage submit → navigation) don't block on a /summary
    // round-trip. The title appears on the thread page once /summary returns.
    // If offline/error, leaves title null — displayTitle derives from preview,
    // and the server will generate an AI title when the thread syncs.
    if (title == null && !draft) {
      final content = preview;
      if (content != null && content.trim().isNotEmpty) {
        final threadId = id;
        unawaited(() async {
          try {
            final response = await api.post<Map<String, dynamic>>(
              '/summary',
              body: {'body': content},
            );
            final generatedTitle = response['title'] as String?;
            if (generatedTitle != null && generatedTitle.isNotEmpty) {
              log.info("Generated AI title for thread $threadId: $generatedTitle");
              await copyWith(title: Value(generatedTitle)).save();
            }
          } catch (e, t) {
            log.warning(
              "AI title generation failed for thread $threadId "
              "(will retry on sync): $e\n$t",
            );
          }
        }());
      }
    }
  }

  Future<void> delete() => copyWith(archivedAt: Value(DateTime.now())).save();

  bool hasTag(Tag tag) {
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
        return users != null && users.isNotEmpty;
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
    final totalExtra = (displayNames.length > 3 ? displayNames.length - 3 : 0) + hiddenCount;
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
        r.endAt ?? r.endOn?.toDateTime() ?? r.startAt ?? r.startOn?.toDateTime();

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
        userSchedule: base._userSchedule,
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
    final generatedRows =
        generated.map((t) => t._schedule!).toList(growable: false);

    // Load all schedule rows for the same link (overrides + base), filter
    // to override rows (occurrence != null), partition by archived.
    final linkId = schedule.linkId;
    List<ScheduleRow> allRows;
    if (linkId != null) {
      allRows = await (Store.get.select(Store.get.schedules)
            ..where((s) => s.linkId.equals(linkId.toBytes())))
          .get();
    } else {
      allRows = await (Store.get.select(Store.get.schedules)
            ..where((s) => s.threadId.equals(base.id.toBytes())))
          .get();
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

    final inherited =
        !picked.isOverride || !overrideHasUserContact(picked.row);

    return Thread._fromStore(
      activity: base._thread,
      priority: base.priority,
      schedule: picked.row,
      userSchedule: base._userSchedule,
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
          outstandingTasks: false,
        ),
        userSchedule: _userSchedule,
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
    _userSchedule,
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
