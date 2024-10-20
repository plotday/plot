part of 'store.dart';

@DataClassName('NoteRow')
class Notes extends UuidStoreTable {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  BlobColumn get userId => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get topicId => blob().map(const UuidConverter())();
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();
}

class NotesBase extends BaseTable {
  NotesBase({
    super.order,
    super.limit,
    super.name,
  }) : super(table: 'note');

  @override
  Insertable<DataClass> fromBase(Map<String, dynamic> json) =>
      NoteRow.fromJson(json);
}

class ContextNotesBase extends NotesBase {
  ContextNotesBase(this.contextPath)
      : super(
          name: 'notes:$contextPath',
          order: 'order',
          limit: 40,
        );

  final Path? contextPath;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    if (contextPath == null) return query;
    return query.filter('context_path', 'cs', contextPath);
  }
}

class TopicNotesBase extends NotesBase {
  TopicNotesBase(this.topicId)
      : super(
          name: 'notes:topic:$topicId',
          order: 'order',
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
  static Future<bool> pull() async => Store.get.pull(table, NotesBase());
  static Future<bool> pullContext(Path? contextPath) async =>
      Store.get.pull(table, ContextNotesBase(contextPath));
  static bool hasMoreContext(Path? contextPath) =>
      Store.get.hasMore(ContextNotesBase(contextPath));
  static Future<bool> pullTopic(TopicId topicId) async =>
      Store.get.pull(table, TopicNotesBase(topicId));
  static bool hasMoreTopic(TopicId topicId) =>
      Store.get.hasMore(TopicNotesBase(topicId));

  static Stream<List<Note>> watchContext(Context? context) {
    final query = Store.get.select(table)..where((t) => t.root.equals(true));
    if (context == null) {
      query.where((t) => t.contextId.isNull());
    } else {
      query.where((t) => t.contextId.equals(context.id.toBytes()));
    }
    query.orderBy(
        [(t) => OrderingTerm.desc(t.root), (t) => OrderingTerm.asc(t.order)]);
    return query
        .watch()
        .map((rows) => rows.map((row) => Note.fromStore(row)).toList());
  }

  static Stream<List<Note>> watchTopic(TopicId topicId) =>
      (Store.get.select(table)
            ..where((t) => t.topicId.equals(topicId.toBytes()))
            ..orderBy([(t) => OrderingTerm.asc(t.order)]))
          .watch()
          .map((rows) => rows.map((row) => Note.fromStore(row)).toList());

  factory Note({
    required Uuid? contextId,
    required String body,
    required Order order,
    bool private = false,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Note.fromStore(NoteRow(
      id: id,
      contextId: contextId,
      userId: Uuid.fromString(base.auth.currentUser!.id),
      root: true,
      topicId: id,
      createdAt: now,
      modifiedAt: now,
      body: body,
      order: order,
      private: private,
    ));
  }

  factory Note.inTopic({
    required Note parent,
    required String body,
    required Order order,
    bool private = false,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Note.fromStore(NoteRow(
      id: id,
      userId: Uuid.fromString(base.auth.currentUser!.id),
      root: false,
      contextId: parent.contextId,
      topicId: parent.topicId,
      createdAt: now,
      modifiedAt: now,
      body: body,
      order: order,
      private: private,
    ));
  }

  Note.fromStore(NoteRow row)
      : super(
          id: row.id,
          userId: row.userId,
          root: row.root,
          contextId: row.contextId,
          topicId: row.topicId,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          body: row.body,
          order: row.order,
          private: row.private,
        );

  Future<void> save() => Store.get.save(table, this);

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }
}
