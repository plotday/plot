import 'api.dart' as api;

class AccountApi {
  /// Requests permanent account deletion. The server cancels billing, bans
  /// the user in Clerk for 14 days (preventing re-login during the grace
  /// period), and schedules manual data purge.
  static Future<void> deleteAccount() async {
    await api.delete<Map<String, dynamic>>('/account');
  }
}
