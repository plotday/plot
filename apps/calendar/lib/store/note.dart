import 'package:drift/drift.dart';

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
