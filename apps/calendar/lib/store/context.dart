import 'package:drift/drift.dart';

import 'table.dart';

class Contexts extends UuidStoreTable {
  TextColumn get name => text()();
  TextColumn get path => text()();
  RealColumn get order => real()();
  IntColumn get pomodoro => integer()();
}
