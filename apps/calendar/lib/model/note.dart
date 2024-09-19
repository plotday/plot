import 'model.dart';
import 'context.dart';
import 'package:plot/store/store.dart' as store;

export 'package:plot/util/order.dart';

typedef NoteID = Uuid;
typedef TopicID = NoteID;

class Note extends LocalModel implements Comparable<Note> {
  static const pageSize = 25;

  static List<Note> _filter(List<Note> notes, Context? context) => notes
      .where((note) =>
          context == null ||
          (note.context != null && context.isParent(note.context!)))
      .toList();

  static Stream<List<Note>> stream(Context? context) {
    fetch(context);
    return _contextStore.stream().map((notes) => _filter(notes, context));
  }

  static Stream<List<Note>> streamTopic(TopicID topicId) {
    fetchTopic(topicId);
    return _topicStore.streamValue(topicId).map((notes) => notes ?? const []);
  }

  static bool more(Context? context) => !_contextDone.contains(context?.id);
  static bool moreTopic(TopicID topicId) => !_topicDone.contains(topicId);

  // Fetch the next page of notes and return all notes.
  static Future<List<Note>> fetch(Context? context) async {
    try {
      var list = _filter(_contextStore.list(), context);
      if (_contextDone.contains(context?.id)) return list;
      var query = base.from('note_x').select().eq("root", true);
      if (context != null) {
        query = query.filter('context_path', 'cs', context.path);
      }
      Order? lastOrder = _contextLastOrder[context?.id];
      if (lastOrder != null) {
        query = query.gt('"order"', lastOrder.toDouble());
      }
      final response =
          await query.order('order', ascending: true).limit(pageSize);
      final models = response.map((r) => Note.fromJson(r)).toList();
      for (final note in models) {
        list = _insert(note);
      }
      if (models.length < pageSize) {
        _contextDone.add(context?.id);
      }
      return list;
    } catch (e, stacktrace) {
      print("Error fetching notes: $e");
      print(stacktrace);
      rethrow;
    }
  }

  static List<Note> getTopic(TopicID topicId) {
    return _topicStore.has(topicId) ? _topicStore.get(topicId) : const [];
  }

  static Future<List<Note>> fetchTopic(TopicID topicId) async {
    List<Note> list = getTopic(topicId);
    if (_topicDone.contains(topicId)) return list;
    Order? lastOrder;
    if (list.isNotEmpty) {
      lastOrder = list.last.order;
    }
    var query = base.from('note').select().eq("topic_id", topicId);
    if (lastOrder != null) {
      query = query.gt('order', lastOrder.toDouble());
    }
    final response = await query
        .order('root', ascending: false)
        .order('order')
        .limit(pageSize);
    final models = response.map((r) => Note.fromJson(r)).toList();
    _appendToTopic(models);
    if (models.length < pageSize) {
      _topicDone.add(topicId);
    }
    return list + models;
  }

  factory Note({
    required Context? context,
    required String body,
    required Order order,
    bool private = false,
  }) {
    final id = generateUuid();
    final DateTime now = DateTime.now();

    return Note._(
      id: id,
      topicId: id,
      contextId: context?.id,
      body: body,
      order: order,
      private: private,
      root: true,
      createdAt: now,
      modifiedAt: now,
    );
  }

  Note.inTopic({
    required Note parent,
    required this.body,
    required this.order,
    this.private = false,
  })  : _userId = null,
        topicId = parent.topicId,
        root = false,
        _contextId = parent._contextId,
        super.create();

  const Note._({
    required this.topicId,
    required ContextID? contextId,
    required this.body,
    required this.root,
    required this.order,
    required this.private,
    required super.id,
    required super.createdAt,
    required super.modifiedAt,
  })  : _userId = null,
        _contextId = contextId;

  factory Note.fromStore(store.Note row) => Note._(
        topicId: row.topicId,
        contextId: row.contextId,
        body: row.body,
        root: row.root,
        order: row.order,
        private: row.private,
        id: row.id,
        createdAt: row.createdAt,
        modifiedAt: row.modifiedAt,
      );

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }

  bool before(Note other) => compareTo(other) < 0;
  bool after(Note other) => compareTo(other) > 0;

  final String? _userId;
  final ContextID? _contextId;
  final TopicID topicId;
  final String body;
  final Order order;
  final bool root;
  final bool private;

  Context? get context =>
      _contextId == null ? null : Context.store.get(_contextId);

  Note copyWith({
    String? body,
    bool? root,
    Order? order,
    bool? private,
  }) {
    return Note._(
      id: id,
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      contextId: _contextId,
      topicId: topicId,
      body: body ?? this.body,
      root: root ?? this.root,
      order: order ?? this.order,
      private: private ?? this.private,
    );
  }

  @override
  List<Object?> get props =>
      super.props +
      [
        _contextId,
        topicId,
        body,
        root,
        order,
        private,
      ];

  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'user_id': _userId ?? base.auth.currentUser?.id,
        'context_id': _contextId?.toString(),
        'topic_id': topicId.toString(),
        'body': body,
        'root': root,
        'order': order.toDouble(),
        'private': private,
      };
  @override
  store.Insertable<store.Note> toStore() => store.NotesCompanion.custom(
        id: store.Constant(id.toBytes()),
        modifiedAt: store.currentDateAndTime,
        body: store.Constant(body),
        root: store.Constant(root),
        order: store.Constant(order.toDouble()),
        private: store.Constant(private),
      );
}
