import 'package:drift/drift.dart';

import 'table.dart';

// Add new values to the end to prevent changing existing int values.
enum AccountProvider { google, outlook }

class Accounts extends IdStoreTable {
  TextColumn get email => text()();
  IntColumn get provider => intEnum<AccountProvider>()();
}

class AccountsBase extends BaseTable {
  AccountsBase() : super(table: 'account');

  @override
  List<Map<String, dynamic>> transform(List<Map<String, dynamic>> rows) {
    return rows.map((json) {
      json['provider'] = json['credentials']['provider'];
      return json;
    }).toList();
  }
}
