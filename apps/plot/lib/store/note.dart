part of 'store.dart';

@DataClassName('NoteRow')
class Notes extends UuidStoreTable with DraftTable, DeletableTable {
  BlobColumn get userId => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  DateTimeColumn get orderedAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get topicId => blob().map(const UuidConverter())();
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
  DateTimeColumn get doAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class NotesBase extends BaseTable {
  NotesBase({
    super.limit,
    super.filterName,
  }) : super(
          table: 'note_x',
          name: 'notes',
          upsertAsUpdate: true,
          order: 'order_x',
          ascending: false,
        );

  @override
  Insertable<DataClass> fromBase(Map<String, dynamic> json) =>
      NoteRow.fromJson(json);
}

class ActivityNotesBase extends NotesBase {
  ActivityNotesBase(this.activityPath)
      : super(
          filterName: activityPath?.toString(),
          limit: 40,
        );

  final Path? activityPath;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    if (activityPath == null) return query;
    return query.filter('activity_path', 'cs', activityPath);
  }
}

class TopicNotesBase extends NotesBase {
  TopicNotesBase(this.topicId)
      : super(
          filterName: 'topic:$topicId',
          limit: 40,
        );

  final Uuid topicId;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    return query.eq('topic_id', topicId.value);
  }

  @override
  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    // Sort the root note before the rest of the topic notes
    return super.sort(query.order('root', ascending: false));
  }
}

class ActiveNotesBase extends NotesBase {
  ActiveNotesBase(this.until);

  final DateTime until;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    return query.lt('do_at', until).not('done_at', 'is', null);
  }
}

class Note extends NoteRow implements Comparable<Note> {
  static TableInfo<Notes, NoteRow> get table => Store.get.notes;

  static Future<void> push() => Store.get.push(table, NotesBase());
  static Future<bool> pull() async =>
      Store.get.pull(PullType.updates, table, NotesBase());
  static Future<bool> pullActivity(Path? activityPath,
          {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          ActivityNotesBase(activityPath));
  static Future<bool> pullActive(DateTime until) async =>
      Store.get.pull(PullType.all, table, ActiveNotesBase(until));
  static bool hasMoreActivity(Path? activityPath) =>
      Store.get.hasMore(ActivityNotesBase(activityPath));
  static Future<bool> pullTopic(TopicId topicId, {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          TopicNotesBase(topicId));
  static bool hasMoreTopic(TopicId topicId) =>
      Store.get.hasMore(TopicNotesBase(topicId));

  static Stream<List<Note>> watchActivity(Activity? activity,
      {bool? deleted = false}) {
    pullActivity(activity?.path);
    final query = Store.get.select(table)..where((t) => t.root.equals(true));
    if (activity == null) {
      query.where((t) => t.activityId.isNull());
    } else {
      query.where((t) => t.activityId.equals(activity.id.toBytes()));
    }
    if (deleted != null) {
      query.where(
          (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
    }

    query.orderBy([
      (t) => OrderingTerm.desc(t.pinned),
      (t) => OrderingTerm(
            expression: const CustomExpression<DateTime>(
                'CASE WHEN do_at IS NOT NULL AND done_at IS NULL AND do_at <= CURRENT_TIMESTAMP THEN do_at ELSE NULL END'),
            mode: OrderingMode.asc,
          ),
      (t) => OrderingTerm.desc(t.order)
    ]);

    return query
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
  }

  static Stream<List<Note>> watchTopic(TopicId topicId,
      {bool? deleted = false}) {
    pullTopic(topicId);
    final query = Store.get.select(table)
      ..where((t) => t.topicId.equals(topicId.toBytes()));
    if (deleted != null) {
      query.where(
          (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
    }
    return (query
          ..orderBy([
            (t) => OrderingTerm.desc(t.root),
            (t) => OrderingTerm.desc(t.order)
          ]))
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
  }

  // Stream of items that are currently active, and will become active before
  // the end of the current day.
  static Stream<List<Note>> watchActive({bool? deleted = false}) {
    return Date.current().switchMap((date) {
      pullActive(date.toEnd());
      final query = Store.get.select(table)
        ..where((t) =>
            t.draft.equals(false) &
            t.doAt.isSmallerThanValue(date.toEnd()) &
            t.doneAt.isNull());
      if (deleted != null) {
        query.where(
            (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
      }
      return query
          .watch()
          .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
    });
  }

  factory Note.draft({
    required Uuid? activityId,
    Note? parent,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Note.fromStore(NoteRow(
      id: id,
      activityId: activityId,
      userId: Base.userId,
      root: parent == null,
      topicId: parent == null ? id : parent.topicId,
      createdAt: now,
      updatedAt: now,
      draft: true,
      body: "",
      order: parent == null ? Order.first() : Order.last(),
      orderedAt: now,
      private: true,
      pinned: false,
    ));
  }

  Note.fromStore(NoteRow row)
      : super(
          activityId: row.activityId,
          body: row.body,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          doAt: row.doAt,
          doneAt: row.doneAt,
          draft: row.draft,
          id: row.id,
          order: row.order,
          orderedAt: row.orderedAt,
          pinned: row.pinned,
          private: row.private,
          root: row.root,
          topicId: row.topicId,
          userId: row.userId,
        );

  @override
  Note copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    bool? draft,
    Uuid? userId,
    String? body,
    Order? order,
    DateTime? orderedAt,
    bool? root,
    bool? pinned,
    bool? private,
    Uuid? topicId,
    Value<Uuid?> activityId = const Value.absent(),
    Value<DateTime?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
  }) {
    final publish = this.draft && draft == false;
    if (doAt.present && doAt.value != null) {
      doneAt = const Value(null);
      order ??= Order.last();
      pinned = false;
    } else if (pinned == true) {
      doAt = const Value(null);
      order ??= Order.last();
    }
    if ((((doneAt.present && doneAt.value != null) ||
                (doAt.present && doAt.value == null)) &&
            !(pinned ?? this.pinned)) ||
        pinned == false) {
      order ??= Order.first();
    }
    if (publish) {
      order ??= (root ?? this.root) ? Order.first() : Order.last();
    }
    return Note.fromStore(super.copyWith(
      id: id ?? this.id,
      createdAt: publish ? DateTime.now() : this.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: deletedAt,
      draft: draft,
      userId: userId ?? this.userId,
      body: body ?? this.body,
      order: order ?? this.order,
      orderedAt: orderedAt ?? (order != null ? DateTime.now() : this.orderedAt),
      root: root ?? this.root,
      pinned: pinned ?? this.pinned,
      private: private ?? this.private,
      topicId: topicId ?? this.topicId,
      activityId: activityId,
      doAt: doAt,
      doneAt: doneAt,
    ));
  }

  Future<void> save() => Store.get.save(table, toCompanion(false), NotesBase());
  bool get doNow {
    return !done && doAt?.isSameOrBefore(DateTime.now()) == true;
  }

  bool get scheduled {
    return doAt?.isAfter(DateTime.now()) == true;
  }

  bool get done => doneAt != null;

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }
}
