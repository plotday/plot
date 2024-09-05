import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:plot/util/uuid.dart';
import 'table.dart';
import 'context.dart';

class Notes extends UuidStoreTable {
  BlobColumn get userId => blob()();
  TextColumn get body => text()();
  RealColumn get order => real()();
  BoolColumn get root => boolean()();
  BoolColumn get private => boolean()();
  BlobColumn get topicId => blob()();
  BlobColumn get contextId => blob().nullable().references(Contexts, #id)();
}

class NotesBase extends BaseTable {
  NotesBase() : super(table: 'notes');
}

class ContextNotesBase extends BaseTable {
  ContextNotesBase(this.contextPath)
      : super(
          table: 'note',
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

class TopicNotesBase extends BaseTable {
  TopicNotesBase(this.topicId)
      : super(
          table: 'note',
          name: 'notes:topic:$topicId',
          order: 'order',
          limit: 40,
        );

  final UUID topicId;

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
