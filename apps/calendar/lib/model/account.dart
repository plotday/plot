import 'package:equatable/equatable.dart';

import 'package:plot/util/api.dart' as api;

enum AccountProvider { google, outlook }

class Account extends Equatable {
  static List<Account> list() {
    // TODO
    return [];
  }

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
      : id = json['id'] as int,
        email = json['email'] as String;

  final int? id;
  final String email;

  @override
  List<Object> get props => [id ?? 0, email];
}
