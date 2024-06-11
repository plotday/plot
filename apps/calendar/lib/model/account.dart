// import 'dart:js_interop';

import 'model.dart';
import 'calendar.dart';
import 'package:plot/util/api.dart' as api;

enum AccountProvider { google, outlook }

class Account extends Model {
  static final store = Store<int, Account>(
    load: () async {
      final json = (await base
          .from('account')
          .select(
              "id,credentials->>provider,email,calendars:calendar(id,name,enabled)")
          .eq("user_id", base.auth.currentUser!.id));
      return json.map(Account.fromJson).map((m) => MapEntry(m.id!, m));
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

  static List<Calendar> _calendarsFromJson(Map<String, dynamic> json) {
    final data = json['calendars'] as List<dynamic>;
    return data
        .map((calendar) => Calendar.fromJson(calendar as Map<String, dynamic>))
        .toList();
  }

  Account.fromJson(Map<String, dynamic> json)
      : email = json['email'] as String,
        provider = AccountProvider.values
            .firstWhere((e) => e.name == json['provider'] as String),
        calendars = _calendarsFromJson(json),
        super(id: json['id'] as int);

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
  final List<Calendar> calendars;

  @override
  List<Object?> get props => [id, email, provider];
}
