part of 'store.dart';

enum AccountProvider { google, outlook }

@DataClassName('AccountRow')
class Accounts extends IdStoreTable {
  TextColumn get email => text()();
  TextColumn get provider => textEnum<AccountProvider>()();
}

class AccountsBase extends BaseTable {
  AccountsBase() : super(table: 'account');

  @override
  Insertable<AccountRow> fromBase(Map<String, dynamic> json) {
    json['provider'] = json['credentials']['provider'];
    return AccountRow.fromJson(json);
  }
}

class Account extends AccountRow {
  static TableInfo<Accounts, AccountRow> get table => Store.get.accounts;

  static Future<Account> add(AccountProvider provider, String code) async {
    final response = await api.post(
      "/sync",
      body: {
        'provider': provider.name,
        'code': code,
      },
    );
    final json = AccountsBase().fromBase(response);
    final row = await Store.get.add(table, json);
    return Account.fromStore(row);
  }

  static Future<void> push() => Store.get.push(table, AccountsBase());
  static Future<void> pull() => Store.get.pull(table, AccountsBase());

  static Stream<List<Account>> watch() => Store.get
      .select(table)
      .watch()
      .map((rows) => rows.map((row) => Account.fromStore(row)).toList());
  static Stream<List<Account>> watchWithCalendars() => Rx.combineLatest2(
      Account.watch(),
      Calendars.watch(),
      (List<Account> accounts, List<Calendar> calendars) =>
          accounts.map((account) {
            final accountCalendars = calendars
                .where((calendar) => calendar.accountId == account.id)
                .toList();
            return Account.fromStore(account, calendars: accountCalendars);
          }).toList());

  Account.fromStore(AccountRow row, {this.calendars})
      : super(
          id: row.id,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          email: row.email,
          provider: row.provider,
        );

  final List<Calendar>? calendars;

  Future<void> save() => Store.get.save(table, this);
}
