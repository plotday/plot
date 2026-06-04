import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:plot/api/twist_api.dart';

/// Suggested defaults for which channels to enable.
class ChannelDefaultSuggestion {
  final Set<String> enabledChannels;

  const ChannelDefaultSuggestion({this.enabledChannels = const {}});
}

/// Low-value email labels that are rarely useful to sync (Sent, Draft, Spam,
/// Gmail category labels, app-specific bracketed labels, receipts).
final _lowValueEmailPatterns = RegExp(
  r'^(SENT|DRAFT|UNREAD|SPAM|TRASH|CATEGORY_\w+)$|^\[.+\]|^receipt',
  caseSensitive: false,
);

/// Informational/read-only channels (holiday & birthday calendars, etc.) that
/// would crowd the user's view if synced.
final _informationalPatterns = RegExp(
  r'(holidays?\s+in\b|public\s+holidays?|national\s+holidays?|birthdays?|contacts?\b|^phases\s+of\s+the\s+moon)',
  caseSensitive: false,
);

/// Computes which channels to enable by default when a connection is first
/// added.
///
/// The model is "sync everything the user would reasonably want by default,
/// then filter out the low-value ones" — for most connectors that means
/// enabling all of their top-level channels. Two signals refine this:
///
/// 1. **Connector hint** ([TwistChannel.enabledByDefault], tri-state): `true`
///    forces the channel on, `false` excludes it (e.g. a shared/holiday
///    calendar, a Gmail spam label, a cascading GitHub org or "Shared with me"
///    drive), and `null` leaves the decision to the heuristic below.
/// 2. **Client heuristic** (for `null`): enable the channel unless its title
///    looks low-value (holidays, birthdays, Sent/Draft/Spam, …).
///
/// Children of a tree are NOT auto-enabled (only explicit `true` ones are), so
/// enabling a connection never fans out across every folder/repo/sub-channel.
class ChannelDefaultSuggester {
  /// Suggest which channels to enable. [channels] is the channel tree returned
  /// by the connector (with [TwistChannel.enabledByDefault] hints populated).
  static ChannelDefaultSuggestion suggest({
    required List<TwistChannel> channels,
  }) {
    if (channels.isEmpty) return const ChannelDefaultSuggestion();
    return ChannelDefaultSuggestion(
      enabledChannels: selectEnabledChannels(channels),
    );
  }

  /// Pure default-selection logic, isolated for testing. Returns the set of
  /// `providerKey:id` channel keys to enable.
  ///
  /// A channel is enabled when:
  /// - [TwistChannel.enabledByDefault] is `true` (at any depth), or
  /// - it is top-level, [TwistChannel.enabledByDefault] is `null`, and its
  ///   title is not low-value.
  ///
  /// Channels with `enabledByDefault == false` are never enabled, and
  /// `null` children are left for the user to pick (avoids enabling every node
  /// of a large tree).
  @visibleForTesting
  static Set<String> selectEnabledChannels(List<TwistChannel> channels) {
    final enabled = <String>{};

    void walk(List<TwistChannel> nodes, {required bool topLevel}) {
      for (final c in nodes) {
        final key = '${c.providerKey}:${c.id}';
        final hint = c.enabledByDefault;
        if (hint == true) {
          enabled.add(key);
        } else if (hint == null && topLevel && !_isLowValueTitle(c.title)) {
          enabled.add(key);
        }
        // hint == false → excluded; null children → user picks.
        if (c.children.isNotEmpty) {
          walk(c.children, topLevel: false);
        }
      }
    }

    walk(channels, topLevel: true);
    return enabled;
  }

  static bool _isLowValueTitle(String title) {
    final t = title.toLowerCase();
    return _informationalPatterns.hasMatch(t) ||
        _lowValueEmailPatterns.hasMatch(t);
  }
}
