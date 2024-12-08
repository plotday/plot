import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:plot/util/uuid.dart';
import 'package:injector/injector.dart';

import 'env.dart';

export 'package:supabase_flutter/supabase_flutter.dart';

class Base {
  static SupabaseClient get client => Injector.appInstance.get<Base>()._client!;
  static Uuid get userId => Injector.appInstance.get<Base>()._userId!;

  static Future<void> init() async {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    Injector.appInstance.registerSingleton<Base>(() => Base());
  }

  Base()
      : _client = Supabase.instance.client,
        _userId =
            Uuid.fromString(Supabase.instance.client.auth.currentUser!.id);

  Base.disconnected() : _userId = Uuid.generate();

  SupabaseClient? _client;
  final Uuid _userId;
}
