import 'model.dart';
import 'package:plot/util/api.dart' as api;
import 'package:plot/store/store.dart' as store;

typedef AccountProvider = store.AccountProvider;
typedef AccountID = int;

class Account extends RemoteModel<AccountID>
    with store.AccountStorable, store.AccountSaveable {
  static Future<Account> add(AccountProvider provider, String code) async {
    final response = await api.post(
      "/sync",
      body: {
        'provider': provider.name,
        'code': code,
      },
    );
    final account = Account.fromStore(store.Account.fromJson(response));
    await account.save();
    return account;
  }

  final String email;
  final AccountProvider provider;

  /* Internal */

  const Account._({
    required super.id,
    required super.createdAt,
    required super.modifiedAt,
    required this.email,
    required this.provider,
  });

  factory Account.fromStore(store.Account row) => Account._(
        id: row.id,
        createdAt: row.createdAt,
        modifiedAt: row.modifiedAt,
        email: row.email,
        provider: row.provider,
      );

  @override
  store.Insertable<store.Account> toStore() => store.AccountsCompanion.custom(
        id: store.Constant(id),
        modifiedAt: store.currentDateAndTime,
        email: store.Constant(email),
        provider: store.Constant(provider.name),
      );

  @override
  List<Object?> get props => super.props + [email, provider];
}
