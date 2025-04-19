part of 'store.dart';

typedef NoteId = Uuid;

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
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get activityId =>
      blob().map(const UuidConverter()).references(Activities, #id)();
}

class NotesBase extends BaseTable {
  NotesBase({
    super.limit,
    super.filterName,
  }) : super(
          table: 'note_x',
          writeTable: 'note',
          name: 'notes',
          order: 'order_x',
          ascending: false,
        );

  @override
  Insertable<DataClass> fromBase(Map<String, dynamic> json) =>
      NoteRow.fromJson(json);
}

class ActivityNotesBase extends NotesBase {
  ActivityNotesBase(this.activityId)
      : super(
          filterName: 'activity:$activityId',
          limit: 40,
        );

  final ActivityId activityId;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    return query.eq('activity_id', activityId.value);
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
  static Future<bool> pullActivity(ActivityId activityId,
          {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          ActivityNotesBase(activityId));
  static bool hasMoreActivity(ActivityId activityId) =>
      Store.get.hasMore(ActivityNotesBase(activityId));

  static Stream<List<Note>> watchActivity(ActivityId activityId,
      {bool? deleted = false}) {
    pullActivity(activityId);
    final query = Store.get.select(table)
      ..where((t) => t.activityId.equals(activityId.toBytes()));
    if (deleted != null) {
      query.where(
          (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
    }
    return (query
          ..orderBy([
            (t) => OrderingTerm.desc(t.pinned),
            (t) => OrderingTerm.desc(t.order)
          ]))
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
  }

  factory Note.draft({
    required ActivityId activityId,
    Note? parent,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Note.fromStore(NoteRow(
      id: id,
      userId: Base.userId,
      activityId: activityId,
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
          id: row.id,
          body: row.body,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          draft: row.draft,
          order: row.order,
          orderedAt: row.orderedAt,
          pinned: row.pinned,
          private: row.private,
          activityId: row.activityId,
          userId: row.userId,
        );

  @override
  Note copyWith({
    NoteId? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    Uuid? userId,
    bool? draft,
    String? body,
    Order? order,
    DateTime? orderedAt,
    bool? pinned,
    bool? private,
    ActivityId? activityId,
  }) {
    final publish = this.draft && draft == false;
    if (pinned != null || publish) {
      order ??= Order.last();
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
      pinned: pinned ?? this.pinned,
      private: private ?? this.private,
      activityId: activityId ?? this.activityId,
    ));
  }

  Future<void> save() => Store.get.save(table, toCompanion(false), NotesBase());

  Future<String> generateTitle() async {
    final response = await api.post(
      "/summary",
      body: {'body': body},
    );
    return response['title'] as String;
  }

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }
}
