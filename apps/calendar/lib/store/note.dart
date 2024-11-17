part of 'store.dart';

@DataClassName('NoteRow')
class Notes extends UuidStoreTable with DraftTable {
  BlobColumn get userId => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  DateTimeColumn get orderedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get topicId => blob().map(const UuidConverter())();
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
  DateTimeColumn get doAt => dateTime().nullable()();
  DateTimeColumn get doneAt => dateTime().nullable()();
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

class Note extends NoteRow implements Comparable<Note> {
  static TableInfo<Notes, NoteRow> get table => Store.get.notes;

  static Future<void> push() => Store.get.push(table, NotesBase());
  static Future<bool> pull() async =>
      Store.get.pull(PullType.updates, table, NotesBase());
  static Future<bool> pullActivity(Path? activityPath,
          {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          ActivityNotesBase(activityPath));
  static bool hasMoreActivity(Path? activityPath) =>
      Store.get.hasMore(ActivityNotesBase(activityPath));
  static Future<bool> pullTopic(TopicId topicId, {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          TopicNotesBase(topicId));
  static bool hasMoreTopic(TopicId topicId) =>
      Store.get.hasMore(TopicNotesBase(topicId));

  static Stream<List<Note>> watchActivity(Activity? activity) {
    pullActivity(activity?.path);
    final query = Store.get.select(table)..where((t) => t.root.equals(true));
    if (activity == null) {
      query.where((t) => t.activityId.isNull());
    } else {
      query.where((t) => t.activityId.equals(activity.id.toBytes()));
    }

    query.orderBy([
      (t) => OrderingTerm.desc(t.pinned),
      (t) => OrderingTerm(
            expression: const CustomExpression<DateTime>(
                'CASE WHEN do_at IS NOT NULL AND do_at <= CURRENT_TIMESTAMP THEN do_at ELSE NULL END'),
            mode: OrderingMode.asc,
          ),
      (t) => OrderingTerm.asc(t.order)
    ]);

    return query
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
  }

  static Stream<List<Note>> watchTopic(TopicId topicId) {
    pullTopic(topicId);
    return (Store.get.select(table)
          ..where((t) => t.topicId.equals(topicId.toBytes()))
          ..orderBy([
            (t) => OrderingTerm.desc(t.root),
            (t) => OrderingTerm.asc(t.order)
          ]))
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
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
      userId: Uuid.fromString(base.auth.currentUser!.id),
      root: parent == null,
      topicId: parent == null ? id : parent.topicId,
      createdAt: now,
      modifiedAt: now,
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
          id: row.id,
          userId: row.userId,
          root: row.root,
          activityId: row.activityId,
          topicId: row.topicId,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          draft: row.draft,
          orderedAt: row.orderedAt,
          doAt: row.doAt,
          doneAt: row.doneAt,
          body: row.body,
          order: row.order,
          private: row.private,
          pinned: row.pinned,
        );

  @override
  Note copyWith({
    Uuid? id,
    DateTime? modifiedAt,
    DateTime? createdAt,
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
    if (publish) {
      order ??= ((root ?? this.root) ? Order.first() : Order.last());
    }
    return Note.fromStore(super.copyWith(
      id: id ?? this.id,
      createdAt: publish ? DateTime.now() : this.createdAt,
      modifiedAt: DateTime.now(),
      draft: draft,
      userId: userId ?? this.userId,
      body: body ?? this.body,
      order: order ?? this.order,
      orderedAt: orderedAt ??
          ((order != null || pinned != null) ? DateTime.now() : this.orderedAt),
      root: root ?? this.root,
      pinned: pinned ?? this.pinned,
      private: private ?? this.private,
      topicId: topicId ?? this.topicId,
      activityId: activityId,
      doAt: doAt,
      doneAt: doneAt,
    ));
  }

  Future<void> save() => Store.get.save(table, toCompanion(false));
  bool get doNow => doAt?.isSameOrBefore(DateTime.now()) == true;
  bool get done => doneAt != null;

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }
}
