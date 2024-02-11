abstract class Env {
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  static const String apiRoot = String.fromEnvironment('API_ROOT');

  static const String googleClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const String googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const String googleAndroidClientId =
      String.fromEnvironment('GOOGLE_ANDROID_CLIENT_ID');
}
