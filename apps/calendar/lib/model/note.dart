import 'package:collection/collection.dart';

import 'model.dart';
import 'context.dart';

export 'package:plot/util/order.dart';

typedef NoteID = UUID;
typedef TopicID = NoteID;

class Note extends LocalModel implements Comparable<Note> {
  static const pageSize = 25;
  static final _contextStore = Store<NoteID, Note>();
  static final _topicStore = Store<NoteID, List<Note>>();
  static final Set<ContextID?> _contextDone = {};
  static final Set<NoteID?> _topicDone = {};

  static List<Note> _filter(List<Note> notes, Context? context) => notes
      .where((note) =>
          context == null ||
          (note.context != null && context.isParent(note.context!)))
      .sorted();

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
      Order? lastOrder;
      if (list.isNotEmpty) {
        lastOrder = list.last.order;
      }
      var query = base.from('note_x').select().eq("root", true);
      if (context != null) {
        query = query.filter('context_path', 'cs', context.path);
      }
      if (lastOrder != null) {
        query = query.gt('"order"', lastOrder.value);
      }
      final response = await query.order('order').limit(pageSize);
      final models = response.map((r) => Note.fromJson(r)).toList();
      for (final note in models) {
        _insert(note);
      }
      if (models.length < pageSize) {
        _contextDone.add(context?.id);
      }
      return list + models;
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
      query = query.gt('order', lastOrder.value);
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
    final id = generateUUID();
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
        createdAt = DateTime.now(),
        modifiedAt = DateTime.now();

  const Note._({
    required this.createdAt,
    required this.modifiedAt,
    required this.topicId,
    required ContextID? contextId,
    required this.body,
    required this.root,
    required this.order,
    required this.private,
    required UUID id,
  })  : _userId = null,
        _contextId = contextId,
        super.withId(id);

  Note.fromJson(Map<String, dynamic> json)
      : createdAt = DateTime.parse(json['created_at'] as String),
        modifiedAt = DateTime.parse(json['modified_at'] as String),
        _userId = json['user_id'] as String,
        _contextId = json['context_id'] != null
            ? parseUUID(json['context_id'] as String)
            : null,
        topicId = parseUUID(json['topic_id'] as String),
        body = json['body'] as String,
        root = json['root'] as bool,
        order = Order.fromString(json['order'] as String),
        private = json['private'] as bool,
        super.fromJson(json);

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }

  bool before(Note other) => compareTo(other) < 0;
  bool after(Note other) => compareTo(other) > 0;

  final DateTime createdAt;
  final DateTime modifiedAt;
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
  Future<Note> save() async {
    try {
      _insert(this);
      final model = await saveToBase("note", Note.fromJson);
      _insert(model);
      return model;
    } catch (e, stacktrace) {
      print("Error saving note: $e");
      print(stacktrace);
      rethrow;
    }
  }

  static void _insert(Note note) {
    if (note.root) {
      _contextStore.put(note.id, note);
    }
    List<Note> topicNotes = List<Note>.from(getTopic(note.topicId));
    topicNotes.removeWhere((n) => n.id == note.id);
    final newPos = lowerBound(topicNotes, note);
    topicNotes.insert(newPos, note);
    _topicStore.put(note.topicId, topicNotes);
  }

  static void _appendToTopic(List<Note> notes) {
    if (notes.isEmpty) return;
    if (notes.first.root) {
      _contextStore.put(notes.first.id, notes.first);
    }
    List<Note> topicNotes = _topicStore.has(notes.first.topicId)
        ? _topicStore.get(notes.first.topicId)
        : const [];
    _topicStore.put(notes.first.topicId, topicNotes + notes);
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

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'user_id': _userId ?? base.auth.currentUser?.id,
        'context_id': _contextId?.toString(),
        'topic_id': topicId.toString(),
        'body': body,
        'root': root,
        'order': order.value,
        'private': private,
      };
}
