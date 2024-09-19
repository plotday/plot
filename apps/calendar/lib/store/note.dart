part of 'store.dart';

@DataClassName('NoteRow')
class Notes extends UuidStoreTable {
  BlobColumn get userId => blob()
      .clientDefault(() => generateUuid().toBytes())
      .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order => real()
      .clientDefault(() => Order.first().toDouble())
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

  final String? contextPath;

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
    return query.eq('topic_id', topicId);
  }

  @override
  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    // Sort the root note before the rest of the topic notes
    return super.sort(query.order('root', ascending: false));
  }
}

class Note extends NoteRow {
  static TableInfo<Notes, NoteRow> get table => Store.get.notes;

  static Future<void> push() => Store.get.push(table, NotesBase());
  static Future<bool> pull() async => Store.get.pull(table, NotesBase());
  static Future<bool> pullContext(String? contextPath) async =>
      Store.get.pull(table, ContextNotesBase(contextPath));
  static Future<bool> pullTopic(Uuid topicId) async =>
      Store.get.pull(table, TopicNotesBase(topicId));

  static Stream<List<Note>> watchContext(String? path) {
    final query = Store.get.select(table);
    if (path != null) {
      query.join([
        innerJoin(Store.get.contexts,
            Store.get.contexts.id.equalsExp(Store.get.notes.contextId))
      ]).where(Store.get.contexts.path.like('$path%'));
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
    final id = generateUuid();
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
    final id = generateUuid();
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
}
