part of 'store.dart';

enum AccountProvider { google, outlook }

@DataClassName('AccountRow')
class Accounts extends Table
    with SyncableTable, IdTable, CreatedTable, DeletableTable {
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
      body: {'provider': provider.name, 'code': code},
    );
    final json = AccountsBase().fromBase(response);
    final row = await Store.get.add(table, json);
    return Account.fromStore(row);
  }

  static Future<bool> push() => Store.get.push(table, AccountsBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.all, table, AccountsBase());

  static Future<List<Account>> get({
    bool withCalendars = false,
    bool? deleted = false,
  }) async {
    if (withCalendars) {
      final joinedRows = await _getWithCalendars(deleted: deleted).get();
      return _groupAccountsWithCalendars(joinedRows);
    }
    return _get(deleted: deleted).get();
  }

  static Stream<List<Account>> watch({
    bool withCalendars = false,
    bool? deleted = false,
  }) {
    if (withCalendars) {
      return _getWithCalendars(
        deleted: deleted,
      ).watch().map(_groupAccountsWithCalendars);
    }
    return _get(deleted: deleted).watch();
  }

  static List<Account> _groupAccountsWithCalendars(
    List<_JoinedAccountCalendar> joinedRows,
  ) {
    final accountCalendarsMap = <int, List<Calendar>>{};
    final accountsMap = <int, AccountRow>{};

    for (final joined in joinedRows) {
      accountsMap[joined.account.id] = joined.account;
      if (joined.calendar != null) {
        accountCalendarsMap
            .putIfAbsent(joined.account.id, () => [])
            .add(Calendar.fromStore(joined.calendar!));
      }
    }

    return accountsMap.values.map((accountRow) {
      final calendars = accountCalendarsMap[accountRow.id] ?? [];
      return Account.fromStore(accountRow, calendars: calendars);
    }).toList();
  }

  static MultiSelectable<Account> _get({bool? deleted = false}) {
    return (Store.get.select(table)..where(
          (t) => deleted == null
              ? const Constant(true)
              : deleted
              ? t.deletedAt.isNotNull()
              : t.deletedAt.isNull(),
        ))
        .map((row) => Account.fromStore(row));
  }

  static MultiSelectable<_JoinedAccountCalendar> _getWithCalendars({
    bool? deleted = false,
  }) {
    final query = Store.get.select(table)
      ..where(
        (t) => deleted == null
            ? const Constant(true)
            : deleted
            ? t.deletedAt.isNotNull()
            : t.deletedAt.isNull(),
      );

    final joinedQuery = query.join([
      leftOuterJoin(
        Store.get.calendars,
        Store.get.calendars.accountId.equalsExp(Store.get.accounts.id) &
            Store.get.calendars.deletedAt.isNull(),
      ),
    ]);

    return joinedQuery.map((row) {
      final account = row.readTable(Store.get.accounts);
      final calendar = row.readTableOrNull(Store.get.calendars);
      return _JoinedAccountCalendar(account: account, calendar: calendar);
    });
  }

  Account.fromStore(AccountRow row, {this.calendars})
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        email: row.email,
        provider: row.provider,
      );

  @override
  Account copyWith({
    int? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    String? email,
    AccountProvider? provider,
  }) => Account.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      deletedAt: deletedAt,
      email: email,
      provider: provider,
    ),
  );

  final List<Calendar>? calendars;

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), AccountsBase());

  @override
  bool operator ==(Object other) {
    return super == other && calendars == (other as Account).calendars;
  }

  @override
  int get hashCode {
    return Object.hash(super.hashCode, calendars.hashCode);
  }
}

class _JoinedAccountCalendar {
  const _JoinedAccountCalendar({required this.account, required this.calendar});

  final AccountRow account;
  final CalendarRow? calendar;
}
