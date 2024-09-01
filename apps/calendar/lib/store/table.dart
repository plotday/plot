import 'package:drift/drift.dart';

class StoreTable extends Table {
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get modifiedAt => dateTime()();
}

class UuidStoreTable extends StoreTable {
  BlobColumn get id => blob()();

  @override
  Set<Column> get primaryKey => {id};
}
