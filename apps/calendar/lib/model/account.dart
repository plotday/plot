import 'model.dart';
import 'calendar.dart';
import 'package:plot/util/api.dart' as api;

enum AccountProvider { google, outlook }

class Account extends Model {
  static final store = Store<int, Account>(
    load: () async {
      return (await base
              .from('account')
              .select("id,provider,email,calendars:calendar(id,name,enabled)")
              .eq("user_id", base.auth.currentUser!.id))
          .map(Account.fromJson)
          .map((m) => MapEntry(m.id!, m));
    },
  );

  static Future<Account> add(AccountProvider provider, String code) async {
    final response = await api.post(
      "/sync",
      body: {
        'provider': provider.name,
        'code': code,
      },
    );
    return Account.fromJson(response);
  }

  Account.fromJson(Map<String, dynamic> json)
      : email = json['email'] as String,
        provider = AccountProvider.values
            .firstWhere((e) => e.name == json['provider'] as String),
        super(id: json['id'] as int) {
    final calendars = json['calendars'] as List<Map<String, dynamic>>;
    for (final calendar in calendars) {
      Calendar.store.put(calendar['id'] as int, Calendar.fromJson(calendar));
    }
  }

  @override
  Map<String, dynamic> toJson() => {
        'email': email,
        'provider': provider.name,
      };

  @override
  Future<Account> save() async {
    final model = await saveToBase("account", Account.fromJson);
    store.put(model.id!, model);
    return model;
  }

  final String email;
  final AccountProvider provider;

  @override
  List<Object?> get props => [id, email, provider];
}
