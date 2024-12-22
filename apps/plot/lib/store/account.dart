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
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('provider');
    return json;
  }

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
  static Future<bool> pull() =>
      Store.get.pull(PullType.all, table, AccountsBase());

  static Stream<List<Account>> watch({bool withCalendars = false}) {
    final accountStream = Store.get
        .select(table)
        .watch()
        .map((rows) => rows.map((row) => Account.fromStore(row)).toList());
    if (withCalendars) {
      return Rx.combineLatest2(
          accountStream,
          Calendar.watch(),
          (List<Account> accounts, List<Calendar> calendars) =>
              accounts.map((account) {
                final accountCalendars = calendars
                    .where((calendar) => calendar.accountId == account.id)
                    .toList();
                return Account.fromStore(account, calendars: accountCalendars);
              }).toList());
    }
    return accountStream;
  }

  Account.fromStore(AccountRow row, {this.calendars})
      : super(
          id: row.id,
          updatedAt: row.updatedAt,
          email: row.email,
          provider: row.provider,
        );

  @override
  Account copyWith(
          {int? id,
          DateTime? updatedAt,
          String? email,
          AccountProvider? provider}) =>
      Account.fromStore(super.copyWith(
        id: id,
        updatedAt: DateTime.now(),
        email: email,
        provider: provider,
      ));

  final List<Calendar>? calendars;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), AccountsBase());
}
